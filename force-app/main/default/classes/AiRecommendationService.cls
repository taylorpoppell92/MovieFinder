/**
 * AiRecommendationService
 *
 * LLM integration layer for AI-powered movie recommendations.
 * All callouts go through the LLM_API Named Credential (base URL:
 * https://api.anthropic.com) so the endpoint and auth headers are
 * managed in Setup, not in code.
 *
 * The Anthropic API key is stored in LLM_Config__mdt (DeveloperName=Default)
 * and injected as the x-api-key request header. The metadata record is
 * gitignored — set the key manually in the org after deployment.
 *
 * Three prompt functions:
 *   parseNaturalLanguageQuery  — slot-fill entity extraction for NL search
 *   rankMovieCandidates        — taste-profile-aware candidate ranking
 *   inferTasteProfile          — swipe-history → taste profile (called by Queueable)
 *
 * Governor limit notes:
 *   - Each method consumes one callout.
 *   - inferTasteProfile also performs one SOQL + one DML (upsert).
 *   - Must not be called after DML in the same transaction; route through
 *     MovieRecommendationQueueable when invoked post-session.
 */
public with sharing class AiRecommendationService {

    // -------------------------------------------------------------------------
    // Custom exception
    // -------------------------------------------------------------------------

    public class AiServiceException extends Exception {}

    // -------------------------------------------------------------------------
    // DTOs
    // -------------------------------------------------------------------------

    public class NlQueryDto {
        @AuraEnabled public List<String> genres;
        @AuraEnabled public Integer      minYear;
        @AuraEnabled public Integer      maxYear;
        @AuraEnabled public List<String> keywords;
        @AuraEnabled public String       mood;
        @AuraEnabled public Decimal      minRating;
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    private static final String NAMED_CRED    = 'callout:LLM_API';
    private static final String MESSAGES_PATH = '/v1/messages';
    private static final String MODEL_ID      = 'claude-haiku-4-5-20251001';
    private static final Integer MAX_TOKENS   = 1024;

    // -------------------------------------------------------------------------
    // Config caching
    // -------------------------------------------------------------------------

    // @TestVisible allows tests to inject a stub record and bypass the SOQL
    @TestVisible
    private static LLM_Config__mdt testConfig;

    private static LLM_Config__mdt cachedConfig;

    private static LLM_Config__mdt getConfig() {
        if (testConfig != null) return testConfig;
        if (cachedConfig == null) {
            cachedConfig = [
                SELECT API_Key__c
                FROM   LLM_Config__mdt
                WHERE  DeveloperName = 'Default'
                LIMIT  1
            ];
        }
        return cachedConfig;
    }

    // -------------------------------------------------------------------------
    // HTTP transport
    // -------------------------------------------------------------------------

    /**
     * Sends a single-turn message to the LLM and returns the plain-text reply.
     * The systemPrompt instructs the model to return only JSON so the caller
     * can parse the result without stripping prose.
     */
    private static String callLlm(String systemPrompt, String userMessage) {
        LLM_Config__mdt cfg = getConfig();

        Map<String, Object> body = new Map<String, Object>{
            'model'      => MODEL_ID,
            'max_tokens' => MAX_TOKENS,
            'system'     => systemPrompt,
            'messages'   => new List<Object>{
                new Map<String, Object>{
                    'role'    => 'user',
                    'content' => userMessage
                }
            }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CRED + MESSAGES_PATH);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('x-api-key', cfg.API_Key__c);
        req.setHeader('anthropic-version', '2023-06-01');
        req.setBody(JSON.serialize(body));
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new AiServiceException(
                'LLM API error ' + res.getStatusCode() + ' — ' + res.getBody()
            );
        }

        // Anthropic Messages API response shape:
        // {"content": [{"type": "text", "text": "..."}], ...}
        Map<String, Object> parsed     = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object>        content    = (List<Object>)        parsed.get('content');
        Map<String, Object> firstBlock = (Map<String, Object>) content[0];
        return (String) firstBlock.get('text');
    }

    // -------------------------------------------------------------------------
    // parseNaturalLanguageQuery
    // -------------------------------------------------------------------------

    /**
     * Extracts structured search filters from a free-text movie query.
     * Example input:  "a scary thriller from the 90s with a twist ending"
     * Example output: NlQueryDto { genres:["Horror","Thriller"], minYear:1990, maxYear:1999 }
     *
     * Returns a best-effort DTO; fields the LLM cannot infer are left null.
     */
    public static NlQueryDto parseNaturalLanguageQuery(String query) {
        if (String.isBlank(query)) {
            return new NlQueryDto();
        }

        String systemPrompt =
            'You are a movie search assistant. Extract structured search filters from the user query. ' +
            'Respond ONLY with valid JSON matching this schema (omit fields you cannot confidently infer): ' +
            '{"genres":["string"],"minYear":number,"maxYear":number,' +
            '"keywords":["string"],"mood":"string","minRating":number}';

        String responseText = callLlm(systemPrompt, query);

        try {
            return (NlQueryDto) JSON.deserialize(extractJson(responseText), NlQueryDto.class);
        } catch (Exception e) {
            throw new AiServiceException(
                'Failed to parse NL query response: ' + responseText + ' — ' + e.getMessage()
            );
        }
    }

    // -------------------------------------------------------------------------
    // rankMovieCandidates
    // -------------------------------------------------------------------------

    /**
     * Re-orders a list of Movie__c candidates by predicted fit for the user.
     * The taste profile JSON (from User_Preference__c.Taste_Profile__c) is sent
     * alongside the candidate summaries.
     *
     * Returns a list of Salesforce Record Ids in best-to-worst order.
     * Falls back to the original order if the LLM response cannot be parsed.
     *
     * @param candidates       Movies to rank (max ~50 recommended to stay within token budget)
     * @param tasteProfileJson JSON string from User_Preference__c.Taste_Profile__c
     */
    public static List<Id> rankMovieCandidates(List<Movie__c> candidates, String tasteProfileJson) {
        if (candidates == null || candidates.isEmpty()) {
            return new List<Id>();
        }

        List<Map<String, Object>> candidateList = new List<Map<String, Object>>();
        for (Movie__c m : candidates) {
            candidateList.add(new Map<String, Object>{
                'id'       => (String) m.Id,
                'title'    => m.Name,
                'genres'   => m.Genre_Tags__c,
                'year'     => m.Release_Year__c,
                'rating'   => m.Aggregate_Rating__c,
                'overview' => m.Overview__c != null ? m.Overview__c.abbreviate(200) : ''
            });
        }

        String systemPrompt =
            'You are a movie recommendation engine. Given a user taste profile and a list of movie ' +
            'candidates, return ONLY a JSON array of Salesforce record Id strings ordered from best ' +
            'to worst match for this user. Example: ["a0000000000001AAA","a0000000000002AAA"]';

        String userMessage =
            'Taste profile: ' + (String.isBlank(tasteProfileJson) ? '{}' : tasteProfileJson) + '\n' +
            'Candidates: ' + JSON.serialize(candidateList);

        String responseText = callLlm(systemPrompt, userMessage);

        try {
            return (List<Id>) JSON.deserialize(extractJson(responseText), List<Id>.class);
        } catch (Exception e) {
            // Graceful degradation: preserve original order rather than surfacing an error
            List<Id> fallback = new List<Id>();
            for (Movie__c m : candidates) {
                fallback.add(m.Id);
            }
            return fallback;
        }
    }

    // -------------------------------------------------------------------------
    // inferTasteProfile
    // -------------------------------------------------------------------------

    /**
     * Analyzes the user's recent interaction history and writes (upserts) a
     * taste profile to User_Preference__c.  Increments Profile_Version__c on
     * every write so callers can detect staleness without reading the JSON.
     *
     * Designed to be called from MovieRecommendationQueueable after each swipe
     * session ends.  Not safe to call in the same transaction as the session-end
     * DML — the Queueable boundary ensures the callout is allowed.
     *
     * No-ops if the user has no interaction history yet.
     *
     * @param userId  The User Id whose profile should be refreshed.
     */
    public static void inferTasteProfile(Id userId) {
        // Read the last 200 interactions — enough signal without hitting token limits
        List<User_Movie_Interaction__c> interactions = [
            SELECT Movie__r.Name,
                   Movie__r.Genre_Tags__c,
                   Movie__r.Release_Year__c,
                   Interaction_Type__c,
                   Interaction_DateTime__c
            FROM   User_Movie_Interaction__c
            WHERE  User__c             = :userId
            AND    Interaction_Type__c IN ('Swipe_Right','Swipe_Left','Thumbs_Up','Thumbs_Down','Watchlisted')
            ORDER BY Interaction_DateTime__c DESC
            LIMIT  200
        ];

        if (interactions.isEmpty()) return;

        List<Map<String, Object>> history = new List<Map<String, Object>>();
        for (User_Movie_Interaction__c rec : interactions) {
            history.add(new Map<String, Object>{
                'title'  => rec.Movie__r.Name,
                'genres' => rec.Movie__r.Genre_Tags__c,
                'year'   => rec.Movie__r.Release_Year__c,
                'action' => rec.Interaction_Type__c
            });
        }

        String systemPrompt =
            'You are a movie taste analyst. Analyze the user\'s interaction history and infer their ' +
            'taste profile. Respond ONLY with valid JSON matching this schema: ' +
            '{"likedGenres":["string"],"dislikedGenres":["string"],"preferredDecades":["string"],' +
            '"moodTags":["string"],"avoidTags":["string"],"ratingThreshold":number}';

        String responseText = callLlm(systemPrompt,
            'Interaction history (most-recent first): ' + JSON.serialize(history));

        String profileJson;
        try {
            profileJson = extractJson(responseText);
            JSON.deserializeUntyped(profileJson); // validate before storing
        } catch (Exception e) {
            throw new AiServiceException(
                'Failed to parse taste profile response: ' + responseText + ' — ' + e.getMessage()
            );
        }

        // Upsert — one User_Preference__c record per user
        List<User_Preference__c> existing = [
            SELECT Id, Profile_Version__c
            FROM   User_Preference__c
            WHERE  User__c = :userId
            LIMIT  1
        ];

        if (!existing.isEmpty()) {
            User_Preference__c pref  = existing[0];
            pref.Taste_Profile__c    = profileJson;
            pref.Last_Updated__c     = Datetime.now();
            pref.Profile_Version__c  =
                (pref.Profile_Version__c == null ? 0 : pref.Profile_Version__c) + 1;
            update pref;
        } else {
            insert new User_Preference__c(
                User__c            = userId,
                Taste_Profile__c   = profileJson,
                Last_Updated__c    = Datetime.now(),
                Profile_Version__c = 1
            );
        }
    }

    // -------------------------------------------------------------------------
    // JSON extraction helper
    // -------------------------------------------------------------------------

    /**
     * Finds and returns the first complete JSON object ({...}) or array ([...])
     * in the given string. Handles LLM responses that include prose preamble or
     * markdown code fences around the JSON payload.
     *
     * Note: Uses a simple brace-depth counter. Works correctly for all valid JSON
     * that does not contain unescaped { or } inside string values — a constraint
     * that holds for all structured outputs this service requests.
     */
    @TestVisible
    private static String extractJson(String text) {
        if (String.isBlank(text)) {
            throw new AiServiceException('Empty LLM response');
        }

        Integer braceIdx   = text.indexOf('{');
        Integer bracketIdx = text.indexOf('[');

        if (braceIdx == -1 && bracketIdx == -1) {
            throw new AiServiceException('No JSON found in LLM response: ' + text.abbreviate(200));
        }

        String openChar;
        String closeChar;
        Integer start;

        if (braceIdx != -1 && (bracketIdx == -1 || braceIdx < bracketIdx)) {
            start     = braceIdx;
            openChar  = '{';
            closeChar = '}';
        } else {
            start     = bracketIdx;
            openChar  = '[';
            closeChar = ']';
        }

        Integer depth  = 0;
        Integer endIdx = -1;
        for (Integer i = start; i < text.length(); i++) {
            String c = text.substring(i, i + 1);
            if      (c == openChar)  depth++;
            else if (c == closeChar) depth--;
            if (depth == 0) {
                endIdx = i + 1;
                break;
            }
        }

        if (endIdx == -1) {
            throw new AiServiceException(
                'Malformed JSON in LLM response: ' + text.abbreviate(200)
            );
        }

        return text.substring(start, endIdx);
    }
}

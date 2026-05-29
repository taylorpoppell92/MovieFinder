/**
 * AiRecommendationServiceTest
 *
 * Full coverage for AiRecommendationService: extractJson helper, all three
 * public methods, and the config-injection (@TestVisible) path.
 *
 * Design notes:
 *   - LLM_Config__mdt is injected via AiRecommendationService.testConfig to
 *     avoid needing the deployed Default record in every org/scratch.
 *   - All HTTP callouts use an inline MockLlmCallout class.
 *   - LLM responses follow the Anthropic Messages API shape:
 *     {"content":[{"type":"text","text":"<payload>"}]}
 */
@IsTest
private class AiRecommendationServiceTest {

    // -------------------------------------------------------------------------
    // Mock callout infrastructure
    // -------------------------------------------------------------------------

    private class MockLlmCallout implements HttpCalloutMock {
        private final Integer statusCode;
        private final String  body;

        public MockLlmCallout(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body       = body;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    // Build a well-formed Anthropic Messages API response around a text payload
    private static String llmResponse(String text) {
        return JSON.serialize(new Map<String, Object>{
            'content' => new List<Object>{
                new Map<String, Object>{ 'type' => 'text', 'text' => text }
            }
        });
    }

    // Inject a stub config so tests never touch the real LLM_Config__mdt record
    private static void injectTestConfig() {
        AiRecommendationService.testConfig = new LLM_Config__mdt(
            API_Key__c = 'test-api-key'
        );
    }

    // -------------------------------------------------------------------------
    // Test data helpers
    // -------------------------------------------------------------------------

    private static User makeUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName          = 'AI',
            LastName           = 'TestUser',
            Email              = 'aitestuser@movfinder.test',
            Username           = 'aitestuser@movfinder.test' + System.currentTimeMillis(),
            Alias              = 'aitest',
            TimeZoneSidKey     = 'America/New_York',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = p.Id
        );
        insert u;
        return u;
    }

    private static Movie__c makeMovie(String title) {
        Movie__c m = new Movie__c(
            Name                = title,
            TMDB_Id__c          = String.valueOf(Math.abs(Crypto.getRandomInteger())),
            Genre_Tags__c       = '878,53',  // Sci-Fi=878, Thriller=53 (real TMDB IDs)
            Release_Year__c     = 2020,
            Aggregate_Rating__c = 8.0,
            Overview__c         = 'A test movie.'
        );
        insert m;
        return m;
    }

    // -------------------------------------------------------------------------
    // extractJson — unit tests (no callout)
    // -------------------------------------------------------------------------

    @IsTest
    static void extractJson_pureJsonObject() {
        String input    = '{"genres":["Sci-Fi"],"minYear":2000}';
        String result   = AiRecommendationService.extractJson(input);
        System.assertEquals(input, result, 'Pure JSON object should be returned unchanged');
    }

    @IsTest
    static void extractJson_objectWithPreamble() {
        String input  = 'Here are the filters: {"genres":["Horror"],"minRating":7.0} Thank you.';
        String result = AiRecommendationService.extractJson(input);
        System.assertEquals('{"genres":["Horror"],"minRating":7.0}', result,
            'Should extract only the JSON object and strip surrounding prose');
    }

    @IsTest
    static void extractJson_arrayResponse() {
        String input  = 'Ranked order: ["id1","id2","id3"]';
        String result = AiRecommendationService.extractJson(input);
        System.assertEquals('["id1","id2","id3"]', result,
            'Should extract JSON array');
    }

    @IsTest
    static void extractJson_markdownFenced() {
        String input  = '```json\n{"likedGenres":["Drama"]}\n```';
        String result = AiRecommendationService.extractJson(input);
        System.assertEquals('{"likedGenres":["Drama"]}', result,
            'Should extract JSON from inside markdown code fence');
    }

    @IsTest
    static void extractJson_throwsOnEmptyString() {
        Boolean threw = false;
        try {
            AiRecommendationService.extractJson('');
        } catch (AiRecommendationService.AiServiceException e) {
            threw = true;
            System.assert(e.getMessage().contains('Empty'), 'Exception message should mention Empty');
        }
        System.assert(threw, 'Should throw AiServiceException on empty input');
    }

    @IsTest
    static void extractJson_throwsWhenNoJsonPresent() {
        Boolean threw = false;
        try {
            AiRecommendationService.extractJson('No JSON here at all.');
        } catch (AiRecommendationService.AiServiceException e) {
            threw = true;
            System.assert(e.getMessage().contains('No JSON'), 'Exception message should mention No JSON');
        }
        System.assert(threw, 'Should throw AiServiceException when no JSON is found');
    }

    // -------------------------------------------------------------------------
    // parseNaturalLanguageQuery
    // -------------------------------------------------------------------------

    @IsTest
    static void parseNlQuery_returnsPopulatedDto() {
        injectTestConfig();
        String nlJson = '{"genres":["Sci-Fi","Thriller"],"minYear":2000,"maxYear":2023,"minRating":7.5}';
        Test.setMock(HttpCalloutMock.class, new MockLlmCallout(200, llmResponse(nlJson)));

        Test.startTest();
            AiRecommendationService.NlQueryDto dto =
                AiRecommendationService.parseNaturalLanguageQuery('a tense sci-fi from the 2000s');
        Test.stopTest();

        System.assertNotEquals(null, dto, 'DTO should not be null');
        System.assertEquals(2, dto.genres.size(), 'Should parse 2 genres');
        System.assert(dto.genres.contains('Sci-Fi'), 'genres should include Sci-Fi');
        System.assertEquals(2000,  dto.minYear,    'minYear should be 2000');
        System.assertEquals(2023,  dto.maxYear,    'maxYear should be 2023');
        System.assertEquals(7.5,   dto.minRating,  'minRating should be 7.5');
    }

    @IsTest
    static void parseNlQuery_blankInputReturnsEmptyDto() {
        injectTestConfig();

        Test.startTest();
            AiRecommendationService.NlQueryDto dto =
                AiRecommendationService.parseNaturalLanguageQuery('   ');
        Test.stopTest();

        System.assertNotEquals(null, dto, 'DTO should not be null for blank input');
        System.assertEquals(null, dto.genres,   'genres should be null for blank input');
        System.assertEquals(null, dto.minYear,  'minYear should be null for blank input');
    }

    @IsTest
    static void parseNlQuery_apiErrorThrowsException() {
        injectTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockLlmCallout(500, '{"error":"server error"}'));

        Boolean threw = false;
        Test.startTest();
            try {
                AiRecommendationService.parseNaturalLanguageQuery('sci-fi movies');
            } catch (AiRecommendationService.AiServiceException e) {
                threw = true;
                System.assert(e.getMessage().contains('500'), 'Exception should include HTTP status code');
            }
        Test.stopTest();

        System.assert(threw, 'Should throw AiServiceException on non-200 LLM response');
    }

    @IsTest
    static void parseNlQuery_llmPreambleIsStripped() {
        injectTestConfig();
        // LLM response contains prose before the JSON — extractJson must handle this
        String responseText = 'Sure! Here are the filters:\n{"genres":["Comedy"],"minYear":1990}';
        Test.setMock(HttpCalloutMock.class, new MockLlmCallout(200, llmResponse(responseText)));

        Test.startTest();
            AiRecommendationService.NlQueryDto dto =
                AiRecommendationService.parseNaturalLanguageQuery('comedy movies from the 90s');
        Test.stopTest();

        System.assertEquals(1, dto.genres.size(), 'Should parse one genre despite prose preamble');
        System.assert(dto.genres.contains('Comedy'), 'Should parse Comedy genre');
        System.assertEquals(1990, dto.minYear, 'Should parse minYear');
    }

    // -------------------------------------------------------------------------
    // rankMovieCandidates
    // -------------------------------------------------------------------------

    @IsTest
    static void rankCandidates_returnsRankedIdList() {
        injectTestConfig();
        Movie__c m1 = makeMovie('Alpha Movie');
        Movie__c m2 = makeMovie('Beta Movie');

        // LLM ranks m2 before m1
        String rankedJson = '["' + m2.Id + '","' + m1.Id + '"]';
        Test.setMock(HttpCalloutMock.class, new MockLlmCallout(200, llmResponse(rankedJson)));

        List<Movie__c> candidates = [
            SELECT Id, Name, Genre_Tags__c, Release_Year__c, Aggregate_Rating__c, Overview__c
            FROM   Movie__c
            WHERE  Id IN (:m1.Id, :m2.Id)
        ];

        Test.startTest();
            List<Id> ranked = AiRecommendationService.rankMovieCandidates(candidates, '{"likedGenres":["Sci-Fi"]}');
        Test.stopTest();

        System.assertEquals(2,     ranked.size(), 'Should return 2 Ids');
        System.assertEquals(m2.Id, ranked[0],     'LLM-preferred movie should be first');
        System.assertEquals(m1.Id, ranked[1],     'Second-ranked movie should be last');
    }

    @IsTest
    static void rankCandidates_emptyListReturnsEmptyList() {
        injectTestConfig();

        Test.startTest();
            List<Id> result = AiRecommendationService.rankMovieCandidates(
                new List<Movie__c>(), '{}');
        Test.stopTest();

        System.assertEquals(0, result.size(), 'Empty candidates should return empty list');
    }

    @IsTest
    static void rankCandidates_badLlmResponseFallsBackToOriginalOrder() {
        injectTestConfig();
        Movie__c m1 = makeMovie('Gamma Movie');
        Movie__c m2 = makeMovie('Delta Movie');

        // LLM returns garbage — should gracefully fall back
        Test.setMock(HttpCalloutMock.class, new MockLlmCallout(200, llmResponse('not valid json at all')));

        List<Movie__c> candidates = [
            SELECT Id, Name, Genre_Tags__c, Release_Year__c, Aggregate_Rating__c, Overview__c
            FROM   Movie__c
            WHERE  Id IN (:m1.Id, :m2.Id)
            ORDER BY Name ASC
        ];

        Test.startTest();
            List<Id> result = AiRecommendationService.rankMovieCandidates(candidates, '{}');
        Test.stopTest();

        System.assertEquals(candidates.size(), result.size(),
            'Fallback should return same number of candidates');
        System.assertEquals(candidates[0].Id, result[0],
            'Fallback should preserve original order');
    }

    // -------------------------------------------------------------------------
    // inferTasteProfile
    // -------------------------------------------------------------------------

    @IsTest
    static void inferProfile_insertsNewUserPreference() {
        injectTestConfig();
        User testUser = makeUser();
        Movie__c movie = makeMovie('Interstellar');

        System.runAs(testUser) {
            insert new User_Movie_Interaction__c(
                User__c             = testUser.Id,
                Movie__c            = movie.Id,
                Interaction_Type__c = 'Swipe_Right',
                Interaction_DateTime__c = Datetime.now()
            );
        }

        String profileJson =
            '{"likedGenres":["Sci-Fi"],"dislikedGenres":[],"preferredDecades":["2010s"],' +
            '"moodTags":["cerebral"],"avoidTags":[],"ratingThreshold":7.0}';
        Test.setMock(HttpCalloutMock.class, new MockLlmCallout(200, llmResponse(profileJson)));

        Test.startTest();
            AiRecommendationService.inferTasteProfile(testUser.Id);
        Test.stopTest();

        List<User_Preference__c> prefs = [
            SELECT Taste_Profile__c, Profile_Version__c, Last_Updated__c, User__c
            FROM   User_Preference__c
            WHERE  User__c = :testUser.Id
        ];

        System.assertEquals(1,           prefs.size(),                    'Should insert exactly one preference record');
        System.assertEquals(profileJson,  prefs[0].Taste_Profile__c,       'Taste profile JSON should match LLM response');
        System.assertEquals(1,           prefs[0].Profile_Version__c,     'Initial version should be 1');
        System.assertNotEquals(null,      prefs[0].Last_Updated__c,        'Last_Updated__c should be set');
    }

    @IsTest
    static void inferProfile_updatesExistingPreferenceAndIncrementsVersion() {
        injectTestConfig();
        User testUser = makeUser();
        Movie__c movie = makeMovie('The Matrix');

        System.runAs(testUser) {
            insert new User_Movie_Interaction__c(
                User__c             = testUser.Id,
                Movie__c            = movie.Id,
                Interaction_Type__c = 'Thumbs_Up',
                Interaction_DateTime__c = Datetime.now()
            );
        }

        // Pre-create the preference at version 3
        insert new User_Preference__c(
            User__c            = testUser.Id,
            Taste_Profile__c   = '{"likedGenres":["Action"]}',
            Last_Updated__c    = Datetime.now().addDays(-1),
            Profile_Version__c = 3
        );

        String updatedProfile =
            '{"likedGenres":["Sci-Fi","Action"],"dislikedGenres":[],"preferredDecades":["1990s"],' +
            '"moodTags":["exciting"],"avoidTags":[],"ratingThreshold":8.0}';
        Test.setMock(HttpCalloutMock.class, new MockLlmCallout(200, llmResponse(updatedProfile)));

        Test.startTest();
            AiRecommendationService.inferTasteProfile(testUser.Id);
        Test.stopTest();

        List<User_Preference__c> prefs = [
            SELECT Taste_Profile__c, Profile_Version__c
            FROM   User_Preference__c
            WHERE  User__c = :testUser.Id
        ];

        System.assertEquals(1,             prefs.size(),                'Should still have exactly one preference record');
        System.assertEquals(updatedProfile, prefs[0].Taste_Profile__c, 'Taste profile should be updated');
        System.assertEquals(4,             prefs[0].Profile_Version__c,'Version should increment from 3 to 4');
    }

    @IsTest
    static void inferProfile_noInteractionsIsNoOp() {
        injectTestConfig();
        User testUser = makeUser();

        // No interactions → inferTasteProfile should return early without calling LLM
        // No mock set up — any callout would throw, proving the no-op path is taken
        Test.startTest();
            AiRecommendationService.inferTasteProfile(testUser.Id);
        Test.stopTest();

        Integer prefCount = [
            SELECT COUNT()
            FROM   User_Preference__c
            WHERE  User__c = :testUser.Id
        ];
        System.assertEquals(0, prefCount, 'No preference record should be created when there are no interactions');
    }
}

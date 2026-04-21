/**
 * TmdbApiService
 *
 * Integration layer for The Movie Database (TMDB) v3 API.
 * All callouts go through the TMDB_API Named Credential so the base URL
 * and any future auth changes are managed in Setup, not in code.
 *
 * API key is stored in TMDB_Config__mdt and injected as a query param on
 * every request per the TMDB v3 authentication model.
 *
 * Governor limit notes:
 *   - Each public method consumes one callout and one HTTP response.
 *   - getWatchProviders makes one callout but parses two sub-arrays.
 *   - Callers that chain multiple methods in a single transaction should
 *     account for the 100-callout limit (or route through Queueable/Future).
 *   - The config query is cached in a static variable so repeated calls
 *     within the same transaction cost only one SOQL query.
 */
public with sharing class TmdbApiService {

    // -------------------------------------------------------------------------
    // Custom exception
    // -------------------------------------------------------------------------

    public class TmdbApiException extends Exception {}

    // -------------------------------------------------------------------------
    // Inner wrapper classes
    // -------------------------------------------------------------------------

    public class MovieResult {
        public String  tmdbId;          // TMDB integer id, surfaced as String
        public String  title;
        public String  posterPath;
        public String  backdropPath;
        public Integer releaseYear;     // null when release_date is absent/blank
        public String  genreTags;       // comma-separated genre_id integers
        public Integer runtimeMinutes;  // only populated by getMovieDetail
        public Decimal voteAverage;
        public String  overview;
        public Decimal popularity;
    }

    public class ProviderResult {
        public Integer providerId;
        public String  providerName;
        public String  logoPath;
        public String  accessType;      // "flatrate" or "free"
    }

    // -------------------------------------------------------------------------
    // Config caching
    // -------------------------------------------------------------------------

    // @TestVisible allows the test class to inject a stub config record,
    // bypassing the SOQL query entirely without changing production behaviour.
    @TestVisible
    private static TMDB_Config__mdt testConfig;

    private static TMDB_Config__mdt cachedConfig;

    private static TMDB_Config__mdt getConfig() {
        if (testConfig != null) {
            return testConfig;
        }
        if (cachedConfig == null) {
            cachedConfig = [
                SELECT API_Key__c, Watch_Region__c
                FROM   TMDB_Config__mdt
                WHERE  DeveloperName = 'Default'
                LIMIT  1
            ];
        }
        return cachedConfig;
    }

    // -------------------------------------------------------------------------
    // URL helpers
    // -------------------------------------------------------------------------

    private static final String BASE_NC  = 'callout:TMDB_API';
    private static final String API_PATH = '/3';

    /**
     * Builds the full URL up to but not including additional query params.
     * The api_key param is always first so callers can safely append
     * &other_param=value.
     */
    private static String buildUrl(String path) {
        TMDB_Config__mdt cfg = getConfig();
        return BASE_NC + API_PATH + path + '?api_key=' + cfg.API_Key__c;
    }

    // -------------------------------------------------------------------------
    // HTTP transport
    // -------------------------------------------------------------------------

    private static HttpResponse makeCallout(String endpoint) {
        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint(endpoint);
        req.setTimeout(30000); // 30 s — TMDB is generally fast; adjust if needed

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new TmdbApiException(
                'TMDB API error ' + res.getStatusCode() +
                ' for endpoint: ' + endpoint +
                ' — ' + res.getBody()
            );
        }
        return res;
    }

    // -------------------------------------------------------------------------
    // JSON parsing helpers
    // -------------------------------------------------------------------------

    /**
     * Parses a raw TMDB movie map (from the results array or a detail response)
     * into a MovieResult. Null-safe throughout — TMDB occasionally omits fields
     * for older entries.
     */
    private static MovieResult parseMovieMap(Map<String, Object> m) {
        MovieResult r = new MovieResult();

        // id comes back as an Integer in the JSON; cast via Object to String
        Object idObj = m.get('id');
        r.tmdbId = idObj != null ? String.valueOf((Integer) idObj) : null;

        r.title       = (String)  m.get('title');
        r.posterPath  = (String)  m.get('poster_path');
        r.backdropPath = (String) m.get('backdrop_path');
        r.overview    = (String)  m.get('overview');

        // vote_average is a Decimal in the JSON
        Object voteObj = m.get('vote_average');
        if (voteObj instanceof Decimal) {
            r.voteAverage = (Decimal) voteObj;
        } else if (voteObj instanceof Integer) {
            r.voteAverage = Decimal.valueOf((Integer) voteObj);
        }

        Object popObj = m.get('popularity');
        if (popObj instanceof Decimal) {
            r.popularity = (Decimal) popObj;
        } else if (popObj instanceof Integer) {
            r.popularity = Decimal.valueOf((Integer) popObj);
        }

        // release_date: "YYYY-MM-DD" — extract the year substring
        String releaseDate = (String) m.get('release_date');
        if (String.isNotBlank(releaseDate) && releaseDate.length() >= 4) {
            try {
                r.releaseYear = Integer.valueOf(releaseDate.substring(0, 4));
            } catch (Exception e) {
                r.releaseYear = null;
            }
        }

        // genre_ids: List<Object> of integers on list endpoints
        Object genreObj = m.get('genre_ids');
        if (genreObj instanceof List<Object>) {
            List<Object> genreList = (List<Object>) genreObj;
            List<String> parts = new List<String>();
            for (Object g : genreList) {
                parts.add(String.valueOf((Integer) g));
            }
            r.genreTags = String.join(parts, ',');
        }

        // runtime only on detail endpoint
        Object rtObj = m.get('runtime');
        if (rtObj instanceof Integer) {
            r.runtimeMinutes = (Integer) rtObj;
        }

        return r;
    }

    /**
     * Extracts the results array from a standard TMDB paginated response
     * and converts each entry into a MovieResult.
     */
    private static List<MovieResult> parseMovieResultsPage(String responseBody) {
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        List<Object> rawResults = (List<Object>) root.get('results');
        List<MovieResult> movies = new List<MovieResult>();

        if (rawResults == null) {
            return movies;
        }

        for (Object item : rawResults) {
            movies.add(parseMovieMap((Map<String, Object>) item));
        }
        return movies;
    }

    // -------------------------------------------------------------------------
    // Public API methods
    // -------------------------------------------------------------------------

    /**
     * Discover movies available on a specific streaming provider (flatrate only),
     * sorted by popularity descending.
     *
     * @param tmdbProviderId  TMDB provider ID (e.g. 8 = Netflix, 9 = Prime)
     * @param page            1-based page number (TMDB supports up to 500)
     */
    public static List<MovieResult> discoverMoviesByProvider(Integer tmdbProviderId, Integer page) {
        TMDB_Config__mdt cfg = getConfig();
        String watchRegion = String.isNotBlank(cfg.Watch_Region__c) ? cfg.Watch_Region__c : 'US';

        String url = buildUrl('/discover/movie')
            + '&watch_region='                 + watchRegion
            + '&with_watch_providers='         + tmdbProviderId
            + '&with_watch_monetization_types=flatrate'
            + '&sort_by=popularity.desc'
            + '&page='                         + page;

        HttpResponse res = makeCallout(url);
        return parseMovieResultsPage(res.getBody());
    }

    /**
     * Fetches the full detail record for a single movie, including runtime.
     *
     * @param tmdbId  TMDB movie ID as a String
     */
    public static MovieResult getMovieDetail(String tmdbId) {
        String url = buildUrl('/movie/' + tmdbId);
        HttpResponse res = makeCallout(url);
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return parseMovieMap(root);
    }

    /**
     * Returns streaming providers for a movie in the configured watch region.
     * Includes both flatrate and free tiers when present.
     *
     * @param tmdbId  TMDB movie ID as a String
     */
    public static List<ProviderResult> getWatchProviders(String tmdbId) {
        String url = buildUrl('/movie/' + tmdbId + '/watch/providers');
        HttpResponse res = makeCallout(url);

        Map<String, Object> root    = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> results = (Map<String, Object>) root.get('results');

        List<ProviderResult> providers = new List<ProviderResult>();

        if (results == null) {
            return providers;
        }

        // Default to US; respect the configured region for future flexibility
        TMDB_Config__mdt cfg = getConfig();
        String region = String.isNotBlank(cfg.Watch_Region__c) ? cfg.Watch_Region__c : 'US';

        Map<String, Object> regionData = (Map<String, Object>) results.get(region);
        if (regionData == null) {
            return providers;
        }

        // Parse flatrate tier
        Object flatrateObj = regionData.get('flatrate');
        if (flatrateObj instanceof List<Object>) {
            for (Object item : (List<Object>) flatrateObj) {
                providers.add(parseProviderMap((Map<String, Object>) item, 'flatrate'));
            }
        }

        // Parse free tier
        Object freeObj = regionData.get('free');
        if (freeObj instanceof List<Object>) {
            for (Object item : (List<Object>) freeObj) {
                providers.add(parseProviderMap((Map<String, Object>) item, 'free'));
            }
        }

        return providers;
    }

    private static ProviderResult parseProviderMap(Map<String, Object> m, String accessType) {
        ProviderResult p = new ProviderResult();
        p.accessType   = accessType;
        p.providerName = (String) m.get('provider_name');
        p.logoPath     = (String) m.get('logo_path');

        Object idObj = m.get('provider_id');
        if (idObj instanceof Integer) {
            p.providerId = (Integer) idObj;
        }

        return p;
    }

    /**
     * Returns TMDB IDs of movies that changed between two dates.
     * Useful for nightly sync jobs that need to refresh stale records.
     *
     * @param startDate  Inclusive start date
     * @param endDate    Inclusive end date
     */
    public static List<String> getChangedMovieIds(Date startDate, Date endDate) {
        String start = formatDate(startDate);
        String endDateString = formatDate(endDate);

        String url = buildUrl('/movie/changes')
            + '&start_date=' + start
            + '&end_date='   + endDateString;

        HttpResponse res = makeCallout(url);
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> rawResults  = (List<Object>) root.get('results');

        List<String> ids = new List<String>();
        if (rawResults == null) {
            return ids;
        }

        for (Object item : rawResults) {
            Map<String, Object> entry = (Map<String, Object>) item;
            Object idObj = entry.get('id');
            if (idObj != null) {
                ids.add(String.valueOf((Integer) idObj));
            }
        }
        return ids;
    }

    /** Formats an Apex Date as the YYYY-MM-DD string TMDB expects. */
    private static String formatDate(Date d) {
        // Datetime.newInstance at midnight then format is the cleanest approach
        return Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0))
                       .format('yyyy-MM-dd');
    }

    /**
     * Full-text movie search against TMDB's search index.
     *
     * @param query  Raw search string — will be URL-encoded automatically
     * @param page   1-based page number
     */
    public static List<MovieResult> searchMovies(String query, Integer page) {
        String encoded = EncodingUtil.urlEncode(query, 'UTF-8');
        String url = buildUrl('/search/movie')
            + '&query=' + encoded
            + '&page='  + page;

        HttpResponse res = makeCallout(url);
        return parseMovieResultsPage(res.getBody());
    }

    /**
     * Returns TMDB's recommendation list for a given movie.
     * Recommendations are based on the movie's genre and keyword profile.
     *
     * @param tmdbId  TMDB movie ID as a String
     * @param page    1-based page number
     */
    public static List<MovieResult> getMovieRecommendations(String tmdbId, Integer page) {
        String url = buildUrl('/movie/' + tmdbId + '/recommendations')
            + '&page=' + page;

        HttpResponse res = makeCallout(url);
        return parseMovieResultsPage(res.getBody());
    }
}

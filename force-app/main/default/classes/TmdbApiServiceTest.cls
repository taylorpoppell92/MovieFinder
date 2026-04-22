/**
 * TmdbApiServiceTest
 *
 * Test coverage for TmdbApiService.
 *
 * Design notes:
 *   - Custom Metadata records deployed to an org ARE visible in tests via
 *     normal SOQL, so in CI/CD the deployed Default record will be found.
 *   - To avoid a hard dependency on a specific org's metadata, we inject a
 *     synthetic config via TmdbApiService.testConfig (@TestVisible static).
 *     This also prevents the SOQL query from running at all during tests.
 *   - All HTTP callouts are intercepted with a configurable MockHttpCallout.
 *   - Each test method asserts on parsed field values, not just code coverage.
 */
@IsTest
private class TmdbApiServiceTest {

    // -------------------------------------------------------------------------
    // Mock HTTP callout infrastructure
    // -------------------------------------------------------------------------

    /**
     * A simple, configurable HttpCalloutMock.
     * Construct with the status code and body you want returned.
     */
    private class MockHttpCallout implements HttpCalloutMock {
        private final Integer statusCode;
        private final String  body;

        public MockHttpCallout(Integer statusCode, String body) {
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

    // -------------------------------------------------------------------------
    // Static mock response bodies
    // -------------------------------------------------------------------------

    // Two-movie discover / search / recommendations page
    private static final String MOCK_MOVIE_PAGE = JSON.serialize(new Map<String, Object>{
        'page'          => 1,
        'total_pages'   => 10,
        'total_results' => 20,
        'results'       => new List<Object>{
            new Map<String, Object>{
                'id'           => 550,
                'title'        => 'Fight Club',
                'poster_path'  => '/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg',
                'backdrop_path'=> '/hZkgoQYus5vegHoetLkCJzb17zJ.jpg',
                'release_date' => '1999-10-15',
                'genre_ids'    => new List<Integer>{ 18, 53 },
                'vote_average' => 8.4,
                'overview'     => 'An insomniac office worker forms an underground fight club.',
                'popularity'   => 61.416
            },
            new Map<String, Object>{
                'id'           => 238,
                'title'        => 'The Godfather',
                'poster_path'  => '/3bhkrj58Vtu7enYsLegHnDmGp.jpg',
                'backdrop_path'=> '/tmU7GeKVybMWFButWEGl2M4GeiP.jpg',
                'release_date' => '1972-03-24',
                'genre_ids'    => new List<Integer>{ 18, 80 },
                'vote_average' => 8.7,
                'overview'     => 'The aging patriarch of an organized crime dynasty.',
                'popularity'   => 112.303
            }
        }
    });

    // Single movie detail (includes runtime, no genre_ids array)
    private static final String MOCK_MOVIE_DETAIL = JSON.serialize(new Map<String, Object>{
        'id'           => 550,
        'title'        => 'Fight Club',
        'poster_path'  => '/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg',
        'backdrop_path'=> '/hZkgoQYus5vegHoetLkCJzb17zJ.jpg',
        'release_date' => '1999-10-15',
        'runtime'      => 139,
        'vote_average' => 8.4,
        'overview'     => 'An insomniac office worker forms an underground fight club.',
        'popularity'   => 61.416
    });

    // Watch providers — US flatrate + one free entry
    private static final String MOCK_WATCH_PROVIDERS = JSON.serialize(new Map<String, Object>{
        'id'      => 550,
        'results' => new Map<String, Object>{
            'US' => new Map<String, Object>{
                'flatrate' => new List<Object>{
                    new Map<String, Object>{
                        'provider_id'   => 8,
                        'provider_name' => 'Netflix',
                        'logo_path'     => '/t2yyOv40HZeVlLjYsCsPHnWLk4W.jpg'
                    },
                    new Map<String, Object>{
                        'provider_id'   => 9,
                        'provider_name' => 'Amazon Prime Video',
                        'logo_path'     => '/emthp39XA2yngMLFOlZHMBtHkP3.jpg'
                    }
                },
                'free' => new List<Object>{
                    new Map<String, Object>{
                        'provider_id'   => 73,
                        'provider_name' => 'Tubi TV',
                        'logo_path'     => '/peURlLlr8jggOwK53fJ5wdQl05y.jpg'
                    }
                }
            }
        }
    });

    // Movie changes list
    private static final String MOCK_CHANGES = JSON.serialize(new Map<String, Object>{
        'results' => new List<Object>{
            new Map<String, Object>{ 'id' => 550,  'adult' => false },
            new Map<String, Object>{ 'id' => 238,  'adult' => false },
            new Map<String, Object>{ 'id' => 1234, 'adult' => false }
        },
        'page'        => 1,
        'total_pages' => 1
    });

    // -------------------------------------------------------------------------
    // Test setup helper — inject synthetic config so tests never hit the DB
    // -------------------------------------------------------------------------

    /**
     * Injects a synthetic TMDB_Config__mdt record via the @TestVisible
     * static. This runs before every test method (called in each test or
     * once via a shared helper — we use a helper to avoid duplication).
     *
     * Note: We cannot use @TestSetup to set a static field — @TestSetup
     * runs in its own context. We call this helper at the top of each test.
     */
    private static void injectTestConfig() {
        TMDB_Config__mdt cfg = new TMDB_Config__mdt(
            DeveloperName   = 'Default',
            MasterLabel     = 'Default',
            API_Key__c      = 'test_api_key_12345',
            Watch_Region__c = 'US'
        );
        TmdbApiService.testConfig = cfg;
        // Also reset the cached config so tests are fully isolated
        // (testConfig takes precedence in getConfig(), but belt-and-suspenders)
    }

    // -------------------------------------------------------------------------
    // Test: discoverMoviesByProvider
    // -------------------------------------------------------------------------

    @IsTest
    static void testDiscoverMoviesByProvider_returnsParsedMovies() {
        injectTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, MOCK_MOVIE_PAGE));

        Test.startTest();
        List<TmdbApiService.MovieResult> movies =
            TmdbApiService.discoverMoviesByProvider(8, 1);
        Test.stopTest();

        Assert.areEqual(2, movies.size(), 'Should return 2 movies from the mock page');

        TmdbApiService.MovieResult first = movies.get(0);
        Assert.areEqual('550',         first.tmdbId,      'tmdbId should be the TMDB integer cast to String');
        Assert.areEqual('Fight Club',  first.title,       'title mismatch');
        Assert.areEqual(1999,          first.releaseYear, 'releaseYear should be parsed from release_date');
        Assert.areEqual('18,53',       first.genreTags,   'genreTags should be comma-joined genre_ids');
        Assert.areEqual(8.4,           first.voteAverage, 'voteAverage mismatch');
        Assert.isNotNull(first.posterPath,   'posterPath should not be null');
        Assert.isNotNull(first.backdropPath, 'backdropPath should not be null');
        Assert.isNotNull(first.overview,     'overview should not be null');

        TmdbApiService.MovieResult second = movies.get(1);
        Assert.areEqual('238', second.tmdbId, 'second movie tmdbId mismatch');
        Assert.areEqual(1972,  second.releaseYear, 'second movie releaseYear mismatch');
    }

    // -------------------------------------------------------------------------
    // Test: getMovieDetail
    // -------------------------------------------------------------------------

    @IsTest
    static void testGetMovieDetail_returnsDetailWithRuntime() {
        injectTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, MOCK_MOVIE_DETAIL));

        Test.startTest();
        TmdbApiService.MovieResult detail = TmdbApiService.getMovieDetail('550');
        Test.stopTest();

        Assert.areEqual('550',        detail.tmdbId,         'tmdbId mismatch');
        Assert.areEqual('Fight Club', detail.title,          'title mismatch');
        Assert.areEqual(139,          detail.runtimeMinutes, 'runtimeMinutes should be populated on detail endpoint');
        Assert.areEqual(1999,         detail.releaseYear,    'releaseYear mismatch');
        Assert.areEqual(8.4,          detail.voteAverage,    'voteAverage mismatch');
        // genre_ids not present in detail response — genreTags should be null
        Assert.isNull(detail.genreTags, 'genreTags should be null when genre_ids absent from detail response');
    }

    // -------------------------------------------------------------------------
    // Test: getWatchProviders
    // -------------------------------------------------------------------------

    @IsTest
    static void testGetWatchProviders_returnsFlatrateAndFree() {
        injectTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, MOCK_WATCH_PROVIDERS));

        Test.startTest();
        List<TmdbApiService.ProviderResult> providers =
            TmdbApiService.getWatchProviders('550');
        Test.stopTest();

        // 2 flatrate + 1 free = 3 total
        Assert.areEqual(3, providers.size(), 'Should return 2 flatrate + 1 free provider');

        TmdbApiService.ProviderResult netflix = providers.get(0);
        Assert.areEqual(8,          netflix.providerId,   'Netflix provider_id should be 8');
        Assert.areEqual('Netflix',  netflix.providerName, 'providerName mismatch');
        Assert.areEqual('flatrate', netflix.accessType,   'accessType should be flatrate');
        Assert.isNotNull(netflix.logoPath, 'logoPath should not be null');

        TmdbApiService.ProviderResult prime = providers.get(1);
        Assert.areEqual(9,                     prime.providerId,   'Prime provider_id should be 9');
        Assert.areEqual('Amazon Prime Video',  prime.providerName, 'providerName mismatch');
        Assert.areEqual('flatrate',            prime.accessType,   'accessType should be flatrate');

        TmdbApiService.ProviderResult tubi = providers.get(2);
        Assert.areEqual(73,        tubi.providerId,   'Tubi provider_id should be 73');
        Assert.areEqual('Tubi TV', tubi.providerName, 'providerName mismatch');
        Assert.areEqual('free',    tubi.accessType,   'accessType should be free');
    }

    @IsTest
    static void testGetWatchProviders_emptyWhenRegionAbsent() {
        injectTestConfig();
        // Response that has results but no US key
        String noRegionBody = JSON.serialize(new Map<String, Object>{
            'id'      => 999,
            'results' => new Map<String, Object>{
                'GB' => new Map<String, Object>{ 'flatrate' => new List<Object>() }
            }
        });
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, noRegionBody));

        Test.startTest();
        List<TmdbApiService.ProviderResult> providers =
            TmdbApiService.getWatchProviders('999');
        Test.stopTest();

        Assert.areEqual(0, providers.size(), 'Should return empty list when US region not in response');
    }

    // -------------------------------------------------------------------------
    // Test: getChangedMovieIds
    // -------------------------------------------------------------------------

    @IsTest
    static void testGetChangedMovieIds_returnsIdStrings() {
        injectTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, MOCK_CHANGES));

        Test.startTest();
        List<String> ids = TmdbApiService.getChangedMovieIds(
            Date.newInstance(2024, 1, 1),
            Date.newInstance(2024, 1, 2)
        );
        Test.stopTest();

        Assert.areEqual(3, ids.size(), 'Should return 3 changed movie IDs');
        Assert.areEqual('550',  ids.get(0), 'First ID mismatch');
        Assert.areEqual('238',  ids.get(1), 'Second ID mismatch');
        Assert.areEqual('1234', ids.get(2), 'Third ID mismatch');
    }

    @IsTest
    static void testGetChangedMovieIds_emptyResultsArray() {
        injectTestConfig();
        String emptyBody = JSON.serialize(new Map<String, Object>{
            'results' => new List<Object>(),
            'page' => 1
        });
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, emptyBody));

        Test.startTest();
        List<String> ids = TmdbApiService.getChangedMovieIds(
            Date.newInstance(2024, 6, 1),
            Date.newInstance(2024, 6, 1)
        );
        Test.stopTest();

        Assert.areEqual(0, ids.size(), 'Should return empty list when results array is empty');
    }

    // -------------------------------------------------------------------------
    // Test: searchMovies
    // -------------------------------------------------------------------------

    @IsTest
    static void testSearchMovies_returnsParsedResults() {
        injectTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, MOCK_MOVIE_PAGE));

        Test.startTest();
        List<TmdbApiService.MovieResult> results =
            TmdbApiService.searchMovies('Fight Club', 1);
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'Should return 2 search results');
        Assert.areEqual('Fight Club', results.get(0).title, 'First result title mismatch');
    }

    @IsTest
    static void testSearchMovies_encodesQueryString() {
        injectTestConfig();
        // We verify the callout goes through without error; URL encoding of
        // special chars is exercised by the EncodingUtil.urlEncode call in the
        // service. The mock intercepts at the Http.send() boundary regardless
        // of the exact URL string.
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, MOCK_MOVIE_PAGE));

        Test.startTest();
        List<TmdbApiService.MovieResult> results =
            TmdbApiService.searchMovies('Star Wars & Sci-Fi', 1);
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'URL encoding should not prevent successful callout');
    }

    // -------------------------------------------------------------------------
    // Test: getMovieRecommendations
    // -------------------------------------------------------------------------

    @IsTest
    static void testGetMovieRecommendations_returnsParsedMovies() {
        injectTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, MOCK_MOVIE_PAGE));

        Test.startTest();
        List<TmdbApiService.MovieResult> recs =
            TmdbApiService.getMovieRecommendations('550', 1);
        Test.stopTest();

        Assert.areEqual(2, recs.size(), 'Should return 2 recommendations');
        Assert.areEqual('550', recs.get(0).tmdbId, 'First recommendation tmdbId mismatch');
        Assert.areEqual('238', recs.get(1).tmdbId, 'Second recommendation tmdbId mismatch');
    }

    // -------------------------------------------------------------------------
    // Test: error handling — non-200 response throws TmdbApiException
    // -------------------------------------------------------------------------

    @IsTest
    static void testMakeCallout_throwsExceptionOnNon200() {
        injectTestConfig();
        String errorBody = '{"status_message":"Invalid API key.","status_code":7}';
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(401, errorBody));

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            TmdbApiService.getMovieDetail('550');
        } catch (TmdbApiService.TmdbApiException e) {
            exceptionThrown = true;
            Assert.isTrue(
                e.getMessage().contains('401'),
                'Exception message should include the HTTP status code'
            );
        }
        Test.stopTest();

        Assert.isTrue(exceptionThrown, 'TmdbApiException should be thrown for a 401 response');
    }

    @IsTest
    static void testMakeCallout_throwsExceptionOn500() {
        injectTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(500, '{"error":"internal server error"}'));

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            TmdbApiService.searchMovies('batman', 1);
        } catch (TmdbApiService.TmdbApiException e) {
            exceptionThrown = true;
            Assert.isTrue(
                e.getMessage().contains('500'),
                'Exception message should include the HTTP status code'
            );
        }
        Test.stopTest();

        Assert.isTrue(exceptionThrown, 'TmdbApiException should be thrown for a 500 response');
    }

    // -------------------------------------------------------------------------
    // Test: edge cases in MovieResult parsing
    // -------------------------------------------------------------------------

    @IsTest
    static void testParseMovieResult_handlesBlankReleaseDate() {
        injectTestConfig();
        String bodyWithBlankDate = JSON.serialize(new Map<String, Object>{
            'page'    => 1,
            'results' => new List<Object>{
                new Map<String, Object>{
                    'id'           => 9999,
                    'title'        => 'Unknown Date Movie',
                    'release_date' => '',     // blank — should not blow up
                    'genre_ids'    => new List<Integer>(),
                    'vote_average' => 0,
                    'popularity'   => 1.0
                }
            }
        });
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, bodyWithBlankDate));

        Test.startTest();
        List<TmdbApiService.MovieResult> results =
            TmdbApiService.discoverMoviesByProvider(8, 1);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Should return one result');
        Assert.isNull(results.get(0).releaseYear, 'releaseYear should be null when release_date is blank');
    }

    @IsTest
    static void testParseMovieResult_handlesNullReleaseDate() {
        injectTestConfig();
        // Omit release_date entirely — JSON.deserializeUntyped returns null for missing keys
        String bodyWithNullDate = JSON.serialize(new Map<String, Object>{
            'page'    => 1,
            'results' => new List<Object>{
                new Map<String, Object>{
                    'id'           => 8888,
                    'title'        => 'No Date Movie',
                    'genre_ids'    => new List<Integer>{ 99 },
                    'vote_average' => 5.5,
                    'popularity'   => 2.0
                }
            }
        });
        Test.setMock(HttpCalloutMock.class, new MockHttpCallout(200, bodyWithNullDate));

        Test.startTest();
        List<TmdbApiService.MovieResult> results =
            TmdbApiService.searchMovies('No Date Movie', 1);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Should return one result');
        Assert.isNull(results.get(0).releaseYear, 'releaseYear should be null when release_date key is absent');
        Assert.areEqual('99', results.get(0).genreTags, 'genreTags should still parse correctly');
    }
}
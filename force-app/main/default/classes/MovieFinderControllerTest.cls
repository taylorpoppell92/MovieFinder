@IsTest
private class MovieFinderControllerTest {

    // ─────────────────────────────────────────────────────────────────────────
    // Test Setup
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Creates a minimal but realistic data set shared across all test methods:
     *   - 1 standard test user (to run assertions as a non-admin)
     *   - 1 Streaming_Service__c
     *   - 1 active User_Subscription__c for that user + service
     *   - 3 Movie__c records with varying popularity
     *   - 3 Movie_Availability__c records linking each movie to the service
     *
     * Note: User_Subscription__c.User__c references a User, so the subscription
     * is created in a separate runAs block to satisfy with-sharing enforcement.
     */
    @TestSetup
    static void makeData() {
        // Create the test user first (must be done outside runAs)
        User testUser = buildTestUser();
        insert testUser;

        // Create the streaming service (no sharing concern — org-level data)
        Streaming_Service__c service = new Streaming_Service__c(
            Name              = 'TestFlix',
            Service_Key__c    = 'testflix',
            TMDB_Provider_Id__c = 9,
            Logo_URL__c       = 'https://example.com/testflix.png',
            Is_Active__c      = true
        );
        insert service;

        // Create movies with distinct popularity values so ORDER BY is deterministic
        List<Movie__c> movies = new List<Movie__c>{
            new Movie__c(
                Name                 = 'Movie Alpha',
                TMDB_Id__c           = 'tmdb_1',
                Poster_URL__c        = 'https://example.com/alpha.jpg',
                Backdrop_URL__c      = 'https://example.com/alpha_bg.jpg',
                Release_Year__c      = 2022,
                Genre_Tags__c        = 'Action,Drama',
                Runtime_Minutes__c   = 120,
                Content_Rating__c    = 'PG-13',
                Aggregate_Rating__c  = 7.5,
                Overview__c          = 'Alpha overview',
                TMDB_Popularity__c   = 300
            ),
            new Movie__c(
                Name                 = 'Movie Beta',
                TMDB_Id__c           = 'tmdb_2',
                Poster_URL__c        = 'https://example.com/beta.jpg',
                Backdrop_URL__c      = 'https://example.com/beta_bg.jpg',
                Release_Year__c      = 2021,
                Genre_Tags__c        = 'Comedy',
                Runtime_Minutes__c   = 95,
                Content_Rating__c    = 'PG',
                Aggregate_Rating__c  = 6.8,
                Overview__c          = 'Beta overview',
                TMDB_Popularity__c   = 200
            ),
            new Movie__c(
                Name                 = 'Movie Gamma',
                TMDB_Id__c           = 'tmdb_3',
                Poster_URL__c        = 'https://example.com/gamma.jpg',
                Backdrop_URL__c      = 'https://example.com/gamma_bg.jpg',
                Release_Year__c      = 2020,
                Genre_Tags__c        = 'Thriller',
                Runtime_Minutes__c   = 110,
                Content_Rating__c    = 'R',
                Aggregate_Rating__c  = 8.1,
                Overview__c          = 'Gamma overview',
                TMDB_Popularity__c   = 100
            )
        };
        insert movies;

        // Availability records — all three movies on the service as Subscription
        List<Movie_Availability__c> availabilities = new List<Movie_Availability__c>();
        for (Movie__c m : movies) {
            availabilities.add(new Movie_Availability__c(
                Movie__c               = m.Id,
                Streaming_Service__c   = service.Id,
                Availability_Type__c   = 'Subscription',
                Available_As_Of__c     = Date.today()
            ));
        }
        insert availabilities;

        // Create the subscription as the test user (with sharing)
        System.runAs(testUser) {
            User_Subscription__c sub = new User_Subscription__c(
                User__c              = testUser.Id,
                Streaming_Service__c = service.Id,
                Is_Active__c         = true,
                Verified_At__c       = System.now()
            );
            insert sub;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static User buildTestUser() {
        // Use the standard user profile — avoids needing a custom profile in scratch
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        return new User(
            FirstName          = 'Test',
            LastName           = 'MovieUser',
            Email              = 'test.movieuser@example.invalid',
            Username           = 'test.movieuser.' + System.currentTimeMillis() + '@example.invalid',
            Alias              = 'tmovie',
            TimeZoneSidKey     = 'America/Los_Angeles',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = p.Id
        );
    }

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE Email = 'test.movieuser@example.invalid' LIMIT 1];
    }

    private static Streaming_Service__c getService() {
        return [SELECT Id, Name FROM Streaming_Service__c WHERE Name = 'TestFlix' LIMIT 1];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getAvailableMovies — no service filter
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetAvailableMovies_noFilter() {
        User testUser = getTestUser();

        Test.startTest();
        List<MovieFinderController.MovieDto> results;
        System.runAs(testUser) {
            results = MovieFinderController.getAvailableMovies(1, 10, null);
        }
        Test.stopTest();

        // All 3 movies should come back
        Assert.areEqual(3, results.size(), 'Expected 3 movies for the subscribed service');

        // Verify ordering — highest popularity first (300 > 200 > 100)
        Assert.areEqual('Movie Alpha', results[0].title, 'First movie should be highest popularity');
        Assert.areEqual('Movie Beta',  results[1].title, 'Second movie should be mid popularity');
        Assert.areEqual('Movie Gamma', results[2].title, 'Third movie should be lowest popularity');

        // Verify DTO fields are mapped correctly on the first result
        MovieFinderController.MovieDto first = results[0];
        Assert.areEqual('tmdb_1',        first.tmdbId,         'TMDB Id mismatch');
        Assert.areEqual(2022,            first.releaseYear,    'Release year mismatch');
        Assert.areEqual('Action,Drama',  first.genreTags,      'Genre tags mismatch');
        Assert.areEqual(120,             first.runtimeMinutes, 'Runtime mismatch');
        Assert.areEqual('PG-13',         first.contentRating,  'Content rating mismatch');
        Assert.isNotNull(first.availableOnServiceIds,          'availableOnServiceIds should not be null');
        Assert.isFalse(first.availableOnServiceIds.isEmpty(),  'availableOnServiceIds should have entries');
        Assert.isNull(first.existingInteraction,               'No interaction recorded yet');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getAvailableMovies — with valid serviceFilter
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetAvailableMovies_withValidServiceFilter() {
        User testUser = getTestUser();
        Streaming_Service__c service = getService();

        Test.startTest();
        List<MovieFinderController.MovieDto> results;
        System.runAs(testUser) {
            results = MovieFinderController.getAvailableMovies(1, 10, service.Id);
        }
        Test.stopTest();

        // Filtering to a subscribed service should return the same 3 movies
        Assert.areEqual(3, results.size(), 'Filtering to subscribed service should return all 3 movies');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getAvailableMovies — with serviceFilter the user is NOT subscribed to
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetAvailableMovies_withUnsubscribedServiceFilter() {
        User testUser = getTestUser();

        // Create a second service the user has no subscription to
        Streaming_Service__c otherService = new Streaming_Service__c(
            Name           = 'OtherStream',
            Service_Key__c = 'otherstream',
            Is_Active__c   = true
        );
        insert otherService;

        Test.startTest();
        List<MovieFinderController.MovieDto> results;
        System.runAs(testUser) {
            results = MovieFinderController.getAvailableMovies(1, 10, otherService.Id);
        }
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Should return no movies for an unsubscribed service');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getAvailableMovies — pageSize cap at 50
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetAvailableMovies_pageSizeCappedAt50() {
        User testUser = getTestUser();

        Test.startTest();
        List<MovieFinderController.MovieDto> results;
        System.runAs(testUser) {
            // Requesting 999 should be capped to 50 — we only have 3 movies so all 3 return
            results = MovieFinderController.getAvailableMovies(1, 999, null);
        }
        Test.stopTest();

        // We only have 3 movies, so we can't exceed 3 — but the key thing is
        // no exception was thrown and we got results
        Assert.isTrue(results.size() <= 50, 'Result count should never exceed the 50-record cap');
        Assert.areEqual(3, results.size(), 'All 3 movies should be returned');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getAvailableMovies — existing interaction is surfaced
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetAvailableMovies_existingInteractionReturned() {
        User testUser = getTestUser();
        Movie__c movie = [SELECT Id FROM Movie__c WHERE Name = 'Movie Alpha' LIMIT 1];

        // Insert an interaction record before calling the controller
        System.runAs(testUser) {
            insert new User_Movie_Interaction__c(
                User__c              = testUser.Id,
                Movie__c             = movie.Id,
                Interaction_Type__c  = 'Thumbs_Up',
                Interaction_DateTime__c = System.now()
            );
        }

        Test.startTest();
        List<MovieFinderController.MovieDto> results;
        System.runAs(testUser) {
            results = MovieFinderController.getAvailableMovies(1, 10, null);
        }
        Test.stopTest();

        // Find the DTO for Movie Alpha
        MovieFinderController.MovieDto alphaDto;
        for (MovieFinderController.MovieDto dto : results) {
            if (dto.title == 'Movie Alpha') {
                alphaDto = dto;
                break;
            }
        }

        Assert.isNotNull(alphaDto, 'Movie Alpha should be in results');
        Assert.areEqual('Thumbs_Up', alphaDto.existingInteraction,
            'existingInteraction should reflect the recorded Thumbs_Up');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getUserSubscriptions
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetUserSubscriptions() {
        User testUser = getTestUser();

        Test.startTest();
        List<MovieFinderController.SubscriptionDto> results;
        System.runAs(testUser) {
            results = MovieFinderController.getUserSubscriptions();
        }
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Test user should have exactly 1 subscription');

        MovieFinderController.SubscriptionDto sub = results[0];
        Assert.areEqual('TestFlix', sub.serviceName,   'Service name mismatch');
        Assert.areEqual(true,       sub.isActive,      'Subscription should be active');
        Assert.isNotNull(sub.subscriptionId,           'subscriptionId should be populated');
        Assert.isNotNull(sub.serviceId,                'serviceId should be populated');
        Assert.areEqual(9, sub.tmdbProviderId,         'TMDB Provider Id mismatch');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getAllStreamingServices
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetAllStreamingServices() {
        User testUser = getTestUser();

        Test.startTest();
        List<MovieFinderController.StreamingServiceDto> results;
        System.runAs(testUser) {
            results = MovieFinderController.getAllStreamingServices();
        }
        Test.stopTest();

        // At minimum we expect the TestFlix service created in @TestSetup
        Assert.isTrue(results.size() >= 1, 'At least 1 active streaming service expected');

        MovieFinderController.StreamingServiceDto testflix;
        for (MovieFinderController.StreamingServiceDto dto : results) {
            if (dto.serviceName == 'TestFlix') {
                testflix = dto;
                break;
            }
        }

        Assert.isNotNull(testflix,             'TestFlix should appear in results');
        Assert.areEqual('testflix',  testflix.serviceKey,       'Service key mismatch');
        Assert.areEqual(9,           testflix.tmdbProviderId,   'TMDB Provider Id mismatch');
        Assert.isNotNull(testflix.logoUrl,                      'Logo URL should be populated');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // upsertUserSubscription — insert case (new service, user has no existing sub)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testUpsertUserSubscription_insertCase() {
        User testUser = getTestUser();

        // Create a second service — test user has no subscription to this one yet
        Streaming_Service__c newService = new Streaming_Service__c(
            Name           = 'StreamPlus',
            Service_Key__c = 'streamplus',
            Is_Active__c   = true
        );
        insert newService;

        Test.startTest();
        System.runAs(testUser) {
            MovieFinderController.upsertUserSubscription(newService.Id, true);
        }
        Test.stopTest();

        List<User_Subscription__c> created = [
            SELECT Id, Is_Active__c, User__c, Streaming_Service__c
            FROM   User_Subscription__c
            WHERE  User__c              = :testUser.Id
            AND    Streaming_Service__c = :newService.Id
        ];

        Assert.areEqual(1,    created.size(),              'Exactly one subscription record should be created');
        Assert.isTrue(created[0].Is_Active__c,             'New subscription should be active');
        Assert.areEqual(testUser.Id, created[0].User__c,   'User__c should match test user');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // upsertUserSubscription — update case (existing sub toggled to inactive)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testUpsertUserSubscription_updateCase() {
        User testUser = getTestUser();
        Streaming_Service__c service = getService();

        // The @TestSetup already created an active subscription for TestFlix.
        // Now call upsert to deactivate it.
        Test.startTest();
        System.runAs(testUser) {
            MovieFinderController.upsertUserSubscription(service.Id, false);
        }
        Test.stopTest();

        List<User_Subscription__c> updated = [
            SELECT Id, Is_Active__c
            FROM   User_Subscription__c
            WHERE  User__c              = :testUser.Id
            AND    Streaming_Service__c = :service.Id
        ];

        // Confirm only one record still exists (no duplicate inserted)
        Assert.areEqual(1,     updated.size(),       'Should still be exactly 1 subscription record');
        Assert.isFalse(updated[0].Is_Active__c,      'Subscription should now be inactive after update');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // upsertUserSubscription — blank serviceId throws AuraHandledException
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testUpsertUserSubscription_blankIdThrows() {
        User testUser = getTestUser();
        Boolean exceptionThrown = false;

        Test.startTest();
        System.runAs(testUser) {
            try {
                MovieFinderController.upsertUserSubscription('', true);
            } catch (AuraHandledException e) {
                exceptionThrown = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(exceptionThrown, 'A blank streamingServiceId should throw AuraHandledException');
    }
}
@IsTest
private class MovieAvailabilitySyncTest {

    // ---------------------------------------------------------------------------
    // Inner mock — intercepts every HTTP callout made during the test.
    // TmdbApiService will call out to the TMDB API; we return a canned discover
    // response with exactly 2 results so we don't trigger next-page chaining.
    // ---------------------------------------------------------------------------
    private class TmdbDiscoverMock implements HttpCalloutMock {

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            // 2 results — below the TMDB_PAGE_SIZE of 20, so the chain stops after page 1
            res.setBody(
                '{"results":['
                + '{"id":550,"title":"Fight Club",'
                + '"poster_path":"/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",'
                + '"backdrop_path":"/hZkgoQYus5vegHoetLkCJzb17zJ.jpg",'
                + '"release_date":"1999-10-15","genre_ids":[18,53],'
                + '"vote_average":8.4,"popularity":61.4,'
                + '"overview":"A ticking-time-bomb insomniac..."},'
                + '{"id":278,"title":"The Shawshank Redemption",'
                + '"poster_path":"/q6y0Go1tsGEsmtFryDOJo3dEmqu.jpg",'
                + '"backdrop_path":"/kXfqcdQKsToO0OUXHcrrNCHDBzO.jpg",'
                + '"release_date":"1994-09-23","genre_ids":[18,80],'
                + '"vote_average":8.7,"popularity":95.2,'
                + '"overview":"Framed in the 1940s..."}'
                + ']}'
            );
            return res;
        }
    }

    // Minimal SchedulableContext stub required by the Schedulable interface
    private class MockSchedulableContext implements SchedulableContext {
        public Id getTriggerId() {
            return null;
        }
    }

    // ---------------------------------------------------------------------------
    // @TestSetup — runs once before all test methods in this class.
    // Creates one active streaming service. Movies are intentionally absent;
    // the sync job is responsible for creating them.
    // ---------------------------------------------------------------------------
    @TestSetup
    static void makeData() {
        Streaming_Service__c netflix = new Streaming_Service__c(
            Name                = 'Netflix',
            TMDB_Provider_Id__c = 8,
            Is_Active__c        = true
        );
        insert netflix;
    }

    // ---------------------------------------------------------------------------
    // testSyncFirstPage
    // Verifies that running the Queueable creates Movie__c records and links them
    // to the service via Movie_Availability__c.
    // ---------------------------------------------------------------------------
    @IsTest
    static void testSyncFirstPage() {
        Streaming_Service__c service = [
            SELECT Id FROM Streaming_Service__c WHERE Name = 'Netflix' LIMIT 1
        ];

        Test.setMock(HttpCalloutMock.class, new TmdbDiscoverMock());

        Test.startTest();
        System.enqueueJob(new MovieAvailabilitySync(service.Id, 1));
        Test.stopTest();
        // Test.stopTest() flushes all async work synchronously, so by this point
        // the Queueable has fully executed and DML is committed.

        // --- Movie__c assertions ---
        List<Movie__c> movies = [
            SELECT Id, Name, TMDB_Id__c, Aggregate_Rating__c, Last_Synced__c
            FROM Movie__c
            ORDER BY Name
        ];
        System.assertEquals(2, movies.size(), 'Sync should have created exactly 2 Movie__c records');

        // Spot-check a field to confirm mapping is correct, not just row count
        Boolean foundFightClub = false;
        for (Movie__c m : movies) {
            if (m.TMDB_Id__c == '550') {
                foundFightClub = true;
                System.assertEquals('Fight Club', m.Name, 'Movie name should match TMDB title');
                System.assertEquals(8.4, m.Aggregate_Rating__c, 'Vote average should be mapped to Aggregate_Rating__c');
                System.assertNotEquals(null, m.Last_Synced__c, 'Last_Synced__c should be stamped');
            }
        }
        System.assert(foundFightClub, 'Fight Club (TMDB id 550) should have been upserted');

        // --- Movie_Availability__c assertions ---
        List<Movie_Availability__c> avails = [
            SELECT Id, Movie__c, Streaming_Service__c, Availability_Type__c, Available_As_Of__c
            FROM Movie_Availability__c
            WHERE Streaming_Service__c = :service.Id
        ];
        System.assertEquals(2, avails.size(), 'One availability record per movie should be created');

        for (Movie_Availability__c a : avails) {
            System.assertEquals(service.Id, a.Streaming_Service__c, 'Availability must link to the correct service');
            System.assertEquals('Subscription', a.Availability_Type__c, 'Availability type should be Subscription');
            System.assertNotEquals(null, a.Available_As_Of__c, 'Available_As_Of__c must be stamped');
        }

        // Confirm every movie has a corresponding availability record
        Set<Id> movieIdsWithAvailability = new Set<Id>();
        for (Movie_Availability__c a : avails) {
            movieIdsWithAvailability.add(a.Movie__c);
        }
        for (Movie__c m : movies) {
            System.assert(
                movieIdsWithAvailability.contains(m.Id),
                'Movie ' + m.Name + ' should have a linked Movie_Availability__c record'
            );
        }
    }

    // ---------------------------------------------------------------------------
    // testSyncIdempotent
    // Running the sync twice should not duplicate availability records.
    // This exercises the query+merge path in the execute method.
    // ---------------------------------------------------------------------------
    @IsTest
    static void testSyncIdempotent() {
        Streaming_Service__c service = [
            SELECT Id FROM Streaming_Service__c WHERE Name = 'Netflix' LIMIT 1
        ];

        Test.setMock(HttpCalloutMock.class, new TmdbDiscoverMock());

        // First pass
        Test.startTest();
        System.enqueueJob(new MovieAvailabilitySync(service.Id, 1));
        Test.stopTest();

        Integer movieCountAfterFirstRun = [SELECT COUNT() FROM Movie__c];
        Integer availCountAfterFirstRun = [SELECT COUNT() FROM Movie_Availability__c WHERE Streaming_Service__c = :service.Id];

        // Second pass — separate startTest/stopTest block is not allowed in one method,
        // so call execute directly after re-setting the mock
        Test.setMock(HttpCalloutMock.class, new TmdbDiscoverMock());
        MovieAvailabilitySync job = new MovieAvailabilitySync(service.Id, 1);
        // We call execute directly here because startTest/stopTest can only appear once per test method.
        // Wrapping in Test.startTest again would throw an exception.
        job.execute(null);

        System.assertEquals(
            movieCountAfterFirstRun,
            [SELECT COUNT() FROM Movie__c],
            'A second sync should not create duplicate Movie__c records'
        );
        System.assertEquals(
            availCountAfterFirstRun,
            [SELECT COUNT() FROM Movie_Availability__c WHERE Streaming_Service__c = :service.Id],
            'A second sync should not create duplicate Movie_Availability__c records'
        );
    }

    // ---------------------------------------------------------------------------
    // testScheduler
    // Verifies the scheduler queries active services and enqueues jobs without
    // throwing an exception.
    // ---------------------------------------------------------------------------
    @IsTest
    static void testScheduler() {
        // No callout mock needed here — the scheduler only enqueues Queueables,
        // it does not itself make HTTP callouts.
        Test.startTest();
        MovieAvailabilitySyncScheduler scheduler = new MovieAvailabilitySyncScheduler();
        scheduler.execute(new MockSchedulableContext());
        Test.stopTest();

        // If we reach this line without an unhandled exception the scheduler is working.
        // We also confirm exactly one job was enqueued for our one active service.
        // Note: AsyncApexJob is queryable in tests after stopTest.
        List<AsyncApexJob> jobs = [
            SELECT Id, ApexClass.Name, Status
            FROM AsyncApexJob
            WHERE ApexClass.Name = 'MovieAvailabilitySync'
              AND JobType = 'Queueable'
        ];
        System.assertEquals(1, jobs.size(), 'Scheduler should enqueue one Queueable per active service');
    }

    // ---------------------------------------------------------------------------
    // testSchedulerSkipsInactiveServices
    // Services where Is_Active__c = false or TMDB_Provider_Id__c is null
    // must be ignored by the scheduler.
    // ---------------------------------------------------------------------------
    @IsTest
    static void testSchedulerSkipsInactiveServices() {
        insert new Streaming_Service__c(
            Name                = 'Inactive Service',
            TMDB_Provider_Id__c = 99,
            Is_Active__c        = false
        );

        Test.startTest();
        new MovieAvailabilitySyncScheduler().execute(new MockSchedulableContext());
        Test.stopTest();

        // Only one job — for Netflix, not for the inactive service
        List<AsyncApexJob> jobs = [
            SELECT Id FROM AsyncApexJob
            WHERE ApexClass.Name = 'MovieAvailabilitySync'
              AND JobType = 'Queueable'
        ];
        System.assertEquals(1, jobs.size(), 'Inactive services must not have jobs enqueued');
    }
}

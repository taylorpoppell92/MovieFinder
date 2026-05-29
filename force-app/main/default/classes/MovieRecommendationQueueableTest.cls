/**
 * MovieRecommendationQueueableTest
 *
 * Coverage for MovieRecommendationQueueable.
 *
 * The Queueable is a thin wrapper around AiRecommendationService.inferTasteProfile,
 * so these tests focus on:
 *   1. The happy path: taste profile is written after execute().
 *   2. The error-swallow contract: an LLM failure does not propagate as an
 *      uncaught exception from execute().
 */
@IsTest
private class MovieRecommendationQueueableTest {

    // -------------------------------------------------------------------------
    // Mock callout infrastructure (mirrors AiRecommendationServiceTest)
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

    private static String llmResponse(String text) {
        return JSON.serialize(new Map<String, Object>{
            'content' => new List<Object>{
                new Map<String, Object>{ 'type' => 'text', 'text' => text }
            }
        });
    }

    // -------------------------------------------------------------------------
    // Test data helpers
    // -------------------------------------------------------------------------

    private static User makeUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName         = 'Queueable',
            LastName          = 'TestUser',
            Email             = 'qtestuser@movfinder.test',
            Username          = 'qtestuser@movfinder.test' + System.currentTimeMillis(),
            Alias             = 'qtest',
            TimeZoneSidKey    = 'America/New_York',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId         = p.Id
        );
        insert u;
        return u;
    }

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------

    @IsTest
    static void execute_writesTasteProfileForUser() {
        // Arrange
        User testUser = makeUser();

        Movie__c movie = new Movie__c(
            Name                = 'Blade Runner 2049',
            TMDB_Id__c          = '335984',
            Genre_Tags__c       = 'Sci-Fi,Drama',
            Release_Year__c     = 2017,
            Aggregate_Rating__c = 8.0
        );
        insert movie;

        System.runAs(testUser) {
            insert new User_Movie_Interaction__c(
                User__c                 = testUser.Id,
                Movie__c                = movie.Id,
                Interaction_Type__c     = 'Swipe_Right',
                Interaction_DateTime__c = Datetime.now()
            );
        }

        AiRecommendationService.testConfig = new LLM_Config__mdt(API_Key__c = 'test-key');

        String profileJson =
            '{"likedGenres":["Sci-Fi"],"dislikedGenres":[],' +
            '"preferredDecades":["2010s"],"moodTags":["atmospheric"],' +
            '"avoidTags":[],"ratingThreshold":7.5}';
        Test.setMock(HttpCalloutMock.class, new MockLlmCallout(200, llmResponse(profileJson)));

        // Act — execute the Queueable synchronously within startTest/stopTest
        Test.startTest();
            System.enqueueJob(new MovieRecommendationQueueable(testUser.Id));
        Test.stopTest();

        // Assert
        List<User_Preference__c> prefs = [
            SELECT Taste_Profile__c, Profile_Version__c
            FROM   User_Preference__c
            WHERE  User__c = :testUser.Id
        ];

        System.assertEquals(1,           prefs.size(),                'Queueable should create one preference record');
        System.assertEquals(profileJson,  prefs[0].Taste_Profile__c, 'Preference should contain LLM-generated profile');
        System.assertEquals(1,           prefs[0].Profile_Version__c,'Initial version should be 1');
    }

    @IsTest
    static void execute_swallowsLlmExceptionWithoutPropagating() {
        // Arrange — LLM returns 500, which causes AiServiceException inside execute()
        User testUser = makeUser();
        AiRecommendationService.testConfig = new LLM_Config__mdt(API_Key__c = 'test-key');

        // Create a minimal interaction so inferTasteProfile proceeds to the callout
        Movie__c movie = new Movie__c(Name = 'Error Movie', TMDB_Id__c = '999001');
        insert movie;
        System.runAs(testUser) {
            insert new User_Movie_Interaction__c(
                User__c                 = testUser.Id,
                Movie__c                = movie.Id,
                Interaction_Type__c     = 'Swipe_Left',
                Interaction_DateTime__c = Datetime.now()
            );
        }

        Test.setMock(HttpCalloutMock.class, new MockLlmCallout(500, '{"error":"internal server error"}'));

        // Act — if the Queueable propagated the exception, Test.stopTest() would throw
        Boolean threw = false;
        Test.startTest();
            try {
                System.enqueueJob(new MovieRecommendationQueueable(testUser.Id));
            } catch (Exception e) {
                threw = true;
            }
        Test.stopTest();

        // Assert — no exception should have escaped execute()
        System.assert(!threw, 'Queueable execute() should swallow LLM exceptions');

        Integer prefCount = [
            SELECT COUNT() FROM User_Preference__c WHERE User__c = :testUser.Id
        ];
        System.assertEquals(0, prefCount, 'No preference record should be created after a failed LLM call');
    }
}

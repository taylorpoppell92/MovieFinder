@IsTest
private class UserInteractionServiceTest {

    // -------------------------------------------------------------------------
    // Test data setup
    // -------------------------------------------------------------------------

    /**
     * Creates one Movie__c and one standard user that all test methods share.
     * Running DML as the test user ensures WITH USER_MODE in the service
     * works correctly and that UserInfo.getUserId() returns a predictable value.
     */
    @TestSetup
    static void makeData() {
        // Create a standard profile user for the tests
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        User testUser = new User(
            FirstName          = 'Movie',
            LastName           = 'Tester',
            Email              = 'movietester@example.invalid',
            Username           = 'movietester_' + Datetime.now().getTime() + '@example.invalid',
            Alias              = 'mvtest',
            TimeZoneSidKey     = 'America/Chicago',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = p.Id
        );
        insert testUser;

        // Movie__c must be created by a user with access; insert as System here
        // since the running context is @TestSetup (no sharing enforcement issue).
        Movie__c movie = new Movie__c(
            Name      = 'Test Movie',
            TMDB_Id__c = '12345'
        );
        insert movie;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE Email = 'movietester@example.invalid' LIMIT 1];
    }

    private static Movie__c getTestMovie() {
        return [SELECT Id FROM Movie__c WHERE TMDB_Id__c = '12345' LIMIT 1];
    }

    private static List<User_Movie_Interaction__c> queryInteractions(
        String userId, String movieId, String interactionType
    ) {
        return [
            SELECT Id, Interaction_Type__c, Interaction_Source__c,
                   Swipe_Session_Id__c, Interaction_DateTime__c
            FROM   User_Movie_Interaction__c
            WHERE  User__c             = :userId
            AND    Movie__c            = :movieId
            AND    Interaction_Type__c = :interactionType
        ];
    }

    // -------------------------------------------------------------------------
    // recordInteraction — insert
    // -------------------------------------------------------------------------

    @IsTest
    static void recordInteraction_insertsNewRecord() {
        User   u     = getTestUser();
        Movie__c m   = getTestMovie();

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Thumbs_Up', 'Lightning');
        }
        Test.stopTest();

        List<User_Movie_Interaction__c> results = queryInteractions(u.Id, m.Id, 'Thumbs_Up');
        Assert.areEqual(1, results.size(), 'Expected one Thumbs_Up interaction to be inserted');
        Assert.areEqual('Lightning', results[0].Interaction_Source__c, 'Source should be Lightning');
        Assert.isNotNull(results[0].Interaction_DateTime__c, 'InteractionDateTime should be populated');
    }

    // -------------------------------------------------------------------------
    // recordInteraction — toggle off (same type called twice = delete)
    // -------------------------------------------------------------------------

    @IsTest
    static void recordInteraction_togglesOffExistingRecord() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();

        // First call inserts
        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Watchlisted', 'Lightning');
        }

        List<User_Movie_Interaction__c> afterInsert = queryInteractions(u.Id, m.Id, 'Watchlisted');
        Assert.areEqual(1, afterInsert.size(), 'Record should exist after first call');

        // Second call on same type should delete it
        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Watchlisted', 'Lightning');
        }
        Test.stopTest();

        List<User_Movie_Interaction__c> afterToggle = queryInteractions(u.Id, m.Id, 'Watchlisted');
        Assert.areEqual(0, afterToggle.size(), 'Record should be deleted after toggle-off');
    }

    // -------------------------------------------------------------------------
    // recordInteraction — mutual exclusivity: Thumbs_Up removes Thumbs_Down
    // -------------------------------------------------------------------------

    @IsTest
    static void recordInteraction_thumbsUpRemovesThumbsDown() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();

        // Seed a Thumbs_Down
        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Thumbs_Down', 'Lightning');
        }

        Assert.areEqual(
            1,
            queryInteractions(u.Id, m.Id, 'Thumbs_Down').size(),
            'Thumbs_Down should exist before test'
        );

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Thumbs_Up', 'Lightning');
        }
        Test.stopTest();

        Assert.areEqual(
            0,
            queryInteractions(u.Id, m.Id, 'Thumbs_Down').size(),
            'Thumbs_Down should be deleted when Thumbs_Up is recorded'
        );
        Assert.areEqual(
            1,
            queryInteractions(u.Id, m.Id, 'Thumbs_Up').size(),
            'Thumbs_Up should now exist'
        );
    }

    // -------------------------------------------------------------------------
    // recordInteraction — mutual exclusivity: Thumbs_Down removes Thumbs_Up
    // -------------------------------------------------------------------------

    @IsTest
    static void recordInteraction_thumbsDownRemovesThumbsUp() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();

        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Thumbs_Up', 'Lightning');
        }

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Thumbs_Down', 'Mobile');
        }
        Test.stopTest();

        Assert.areEqual(
            0,
            queryInteractions(u.Id, m.Id, 'Thumbs_Up').size(),
            'Thumbs_Up should be deleted when Thumbs_Down is recorded'
        );
        Assert.areEqual(
            1,
            queryInteractions(u.Id, m.Id, 'Thumbs_Down').size(),
            'Thumbs_Down should now exist'
        );
    }

    // -------------------------------------------------------------------------
    // recordInteraction — invalid inputs throw AuraHandledException
    // -------------------------------------------------------------------------

    @IsTest
    static void recordInteraction_blankMovieId_throwsException() {
        User u = getTestUser();
        Boolean threw = false;

        Test.startTest();
        System.runAs(u) {
            try {
                UserInteractionService.recordInteraction('', 'Thumbs_Up', 'Lightning');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Should throw AuraHandledException for blank movieId');
    }

    @IsTest
    static void recordInteraction_invalidType_throwsException() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();
        Boolean  threw = false;

        Test.startTest();
        System.runAs(u) {
            try {
                UserInteractionService.recordInteraction(m.Id, 'Swipe_Right', 'Lightning');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Should throw AuraHandledException for an interaction type not valid in recordInteraction');
    }

    // -------------------------------------------------------------------------
    // startSwipeSession
    // -------------------------------------------------------------------------

    @IsTest
    static void startSwipeSession_returnsNonBlankString() {
        User u = getTestUser();
        String sessionId;

        Test.startTest();
        System.runAs(u) {
            sessionId = UserInteractionService.startSwipeSession();
        }
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(sessionId), 'Session ID should not be blank');
        Assert.areEqual(36, sessionId.length(), 'Session ID should be exactly 36 characters');
    }

    @IsTest
    static void startSwipeSession_returnsUniqueIds() {
        User u = getTestUser();
        String id1, id2;

        Test.startTest();
        System.runAs(u) {
            id1 = UserInteractionService.startSwipeSession();
            id2 = UserInteractionService.startSwipeSession();
        }
        Test.stopTest();

        Assert.areNotEqual(id1, id2, 'Each call should return a unique session ID');
    }

    // -------------------------------------------------------------------------
    // recordSwipe — swipe right
    // -------------------------------------------------------------------------

    @IsTest
    static void recordSwipe_right_insertsSwipeRight() {
        User     u       = getTestUser();
        Movie__c m       = getTestMovie();
        String   session = 'test-session-id-right-00000000000';

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordSwipe(m.Id, 'right', session);
        }
        Test.stopTest();

        List<User_Movie_Interaction__c> results = queryInteractions(u.Id, m.Id, 'Swipe_Right');
        Assert.areEqual(1, results.size(), 'Expected one Swipe_Right record');
        Assert.areEqual(session, results[0].Swipe_Session_Id__c, 'SwipeSessionId should match');
        Assert.areEqual('Swipe_Session', results[0].Interaction_Source__c, 'Source should be Swipe_Session');
    }

    // -------------------------------------------------------------------------
    // recordSwipe — swipe left
    // -------------------------------------------------------------------------

    @IsTest
    static void recordSwipe_left_insertsSwipeLeft() {
        User     u       = getTestUser();
        Movie__c m       = getTestMovie();
        String   session = 'test-session-id-left-000000000000';

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordSwipe(m.Id, 'left', session);
        }
        Test.stopTest();

        List<User_Movie_Interaction__c> results = queryInteractions(u.Id, m.Id, 'Swipe_Left');
        Assert.areEqual(1, results.size(), 'Expected one Swipe_Left record');
        Assert.areEqual(session, results[0].Swipe_Session_Id__c);
    }

    // -------------------------------------------------------------------------
    // recordSwipe — update existing record in same session
    // -------------------------------------------------------------------------

    @IsTest
    static void recordSwipe_sameSession_updatesExistingRecord() {
        User     u       = getTestUser();
        Movie__c m       = getTestMovie();
        String   session = 'test-session-id-update-0000000000';

        // First swipe is left
        System.runAs(u) {
            UserInteractionService.recordSwipe(m.Id, 'left', session);
        }

        // Same session, user changes mind and swipes right
        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordSwipe(m.Id, 'right', session);
        }
        Test.stopTest();

        // Should still be exactly one record, now showing Swipe_Right
        List<User_Movie_Interaction__c> allSwipes = [
            SELECT Id, Interaction_Type__c
            FROM   User_Movie_Interaction__c
            WHERE  User__c             = :u.Id
            AND    Movie__c            = :m.Id
            AND    Swipe_Session_Id__c = :session
        ];
        Assert.areEqual(1, allSwipes.size(), 'Should still be only one record for this session');
        Assert.areEqual('Swipe_Right', allSwipes[0].Interaction_Type__c, 'Direction should be updated to Swipe_Right');
    }

    // -------------------------------------------------------------------------
    // recordSwipe — invalid direction throws AuraHandledException
    // -------------------------------------------------------------------------

    @IsTest
    static void recordSwipe_invalidDirection_throwsException() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();
        Boolean  threw = false;

        Test.startTest();
        System.runAs(u) {
            try {
                UserInteractionService.recordSwipe(m.Id, 'up', 'any-session-id-000000000000000000');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Invalid direction should throw AuraHandledException');
    }

    // -------------------------------------------------------------------------
    // getUserInteractions
    // -------------------------------------------------------------------------

    @IsTest
    static void getUserInteractions_returnsAllInteractionsForMovie() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();

        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Watchlisted', 'Lightning');
            UserInteractionService.recordInteraction(m.Id, 'Watched',     'Lightning');
        }

        Test.startTest();
        List<UserInteractionService.InteractionDto> dtos;
        System.runAs(u) {
            dtos = UserInteractionService.getUserInteractions(m.Id);
        }
        Test.stopTest();

        Assert.areEqual(2, dtos.size(), 'Should return both interactions');

        // Collect types returned
        Set<String> returnedTypes = new Set<String>();
        for (UserInteractionService.InteractionDto dto : dtos) {
            returnedTypes.add(dto.interactionType);
            Assert.areEqual(m.Id, dto.movieId, 'movieId on DTO should match');
            Assert.isNotNull(dto.interactionId, 'interactionId should be populated');
            Assert.isNotNull(dto.interactionDateTime, 'interactionDateTime should be populated');
        }

        Assert.isTrue(returnedTypes.contains('Watchlisted'), 'Watchlisted should be in results');
        Assert.isTrue(returnedTypes.contains('Watched'),     'Watched should be in results');
    }

    @IsTest
    static void getUserInteractions_returnsEmptyListWhenNoneExist() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();

        Test.startTest();
        List<UserInteractionService.InteractionDto> dtos;
        System.runAs(u) {
            dtos = UserInteractionService.getUserInteractions(m.Id);
        }
        Test.stopTest();

        Assert.isNotNull(dtos, 'Should return an empty list, not null');
        Assert.areEqual(0, dtos.size(), 'Should be empty when no interactions exist');
    }

    // -------------------------------------------------------------------------
    // clearInteraction
    // -------------------------------------------------------------------------

    @IsTest
    static void clearInteraction_deletesExistingRecord() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();

        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Thumbs_Up', 'Lightning');
        }

        Assert.areEqual(
            1,
            queryInteractions(u.Id, m.Id, 'Thumbs_Up').size(),
            'Record should exist before clearInteraction'
        );

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.clearInteraction(m.Id, 'Thumbs_Up');
        }
        Test.stopTest();

        Assert.areEqual(
            0,
            queryInteractions(u.Id, m.Id, 'Thumbs_Up').size(),
            'Record should be deleted after clearInteraction'
        );
    }

    @IsTest
    static void clearInteraction_noOpWhenRecordDoesNotExist() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();
        Boolean  threw = false;

        // No interaction seeded — should complete silently
        Test.startTest();
        System.runAs(u) {
            try {
                UserInteractionService.clearInteraction(m.Id, 'Watched');
            } catch (Exception e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isFalse(threw, 'clearInteraction should be a no-op when record does not exist');
    }
}
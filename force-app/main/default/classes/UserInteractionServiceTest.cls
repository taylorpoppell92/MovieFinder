@IsTest
private class UserInteractionServiceTest {

    // -------------------------------------------------------------------------
    // Test data setup
    // -------------------------------------------------------------------------

    @TestSetup
    static void makeData() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        User testUser1 = new User(
            FirstName         = 'Movie',
            LastName          = 'Tester',
            Email             = 'movietester@example.invalid',
            Username          = 'movietester_' + Datetime.now().getTime() + '@example.invalid',
            Alias             = 'mvtest',
            TimeZoneSidKey    = 'America/Chicago',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId         = p.Id
        );

        User testUser2 = new User(
            FirstName         = 'Movie',
            LastName          = 'Partner',
            Email             = 'moviepartner@example.invalid',
            Username          = 'moviepartner_' + Datetime.now().getTime() + '@example.invalid',
            Alias             = 'mvpart',
            TimeZoneSidKey    = 'America/Chicago',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId         = p.Id
        );

        insert new List<User>{ testUser1, testUser2 };

        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'MovieFinder_User' LIMIT 1];
        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = testUser1.Id, PermissionSetId = ps.Id),
            new PermissionSetAssignment(AssigneeId = testUser2.Id, PermissionSetId = ps.Id)
        };

        Movie__c movie1 = new Movie__c(
            Name               = 'Test Movie',
            TMDB_Id__c         = '12345',
            TMDB_Popularity__c = 100
        );
        Movie__c movie2 = new Movie__c(
            Name               = 'Test Movie 2',
            TMDB_Id__c         = '99999',
            TMDB_Popularity__c = 50
        );
        insert new List<Movie__c>{ movie1, movie2 };

        Streaming_Service__c svc = new Streaming_Service__c(
            Name                = 'Test Service',
            Service_Key__c      = 'testservice',
            TMDB_Provider_Id__c = 999,
            Is_Active__c        = true
        );
        insert svc;

        insert new User_Subscription__c(
            User__c              = testUser1.Id,
            Streaming_Service__c = svc.Id,
            Is_Active__c         = true
        );

        insert new List<Movie_Availability__c>{
            new Movie_Availability__c(
                Movie__c             = movie1.Id,
                Streaming_Service__c = svc.Id,
                Availability_Type__c = 'Subscription',
                Available_As_Of__c   = Datetime.now()
            ),
            new Movie_Availability__c(
                Movie__c             = movie2.Id,
                Streaming_Service__c = svc.Id,
                Availability_Type__c = 'Subscription',
                Available_As_Of__c   = Datetime.now()
            )
        };
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE Email = 'movietester@example.invalid' LIMIT 1];
    }

    private static User getTestUser2() {
        return [SELECT Id FROM User WHERE Email = 'moviepartner@example.invalid' LIMIT 1];
    }

    private static Movie__c getTestMovie() {
        return [SELECT Id FROM Movie__c WHERE TMDB_Id__c = '12345' LIMIT 1];
    }

    private static Movie__c getTestMovie2() {
        return [SELECT Id FROM Movie__c WHERE TMDB_Id__c = '99999' LIMIT 1];
    }

    private static List<User_Movie_Interaction__c> queryInteractions(
        String userId, String movieId, String interactionType
    ) {
        return [
            SELECT Id, Interaction_Type__c, Interaction_Source__c,
                   Swipe_Session__c, Interaction_DateTime__c
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
        User     u = getTestUser();
        Movie__c m = getTestMovie();

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

        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Watchlisted', 'Lightning');
        }
        Assert.areEqual(1, queryInteractions(u.Id, m.Id, 'Watchlisted').size(), 'Record should exist after first call');

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Watchlisted', 'Lightning');
        }
        Test.stopTest();

        Assert.areEqual(0, queryInteractions(u.Id, m.Id, 'Watchlisted').size(), 'Record should be deleted after toggle-off');
    }

    // -------------------------------------------------------------------------
    // recordInteraction — mutual exclusivity
    // -------------------------------------------------------------------------

    @IsTest
    static void recordInteraction_thumbsUpRemovesThumbsDown() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();

        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Thumbs_Down', 'Lightning');
        }

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordInteraction(m.Id, 'Thumbs_Up', 'Lightning');
        }
        Test.stopTest();

        Assert.areEqual(0, queryInteractions(u.Id, m.Id, 'Thumbs_Down').size(), 'Thumbs_Down should be deleted');
        Assert.areEqual(1, queryInteractions(u.Id, m.Id, 'Thumbs_Up').size(),   'Thumbs_Up should now exist');
    }

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

        Assert.areEqual(0, queryInteractions(u.Id, m.Id, 'Thumbs_Up').size(),   'Thumbs_Up should be deleted');
        Assert.areEqual(1, queryInteractions(u.Id, m.Id, 'Thumbs_Down').size(), 'Thumbs_Down should now exist');
    }

    // -------------------------------------------------------------------------
    // recordInteraction — invalid inputs
    // -------------------------------------------------------------------------

    @IsTest
    static void recordInteraction_blankMovieId_throwsException() {
        User    u     = getTestUser();
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
        User     u     = getTestUser();
        Movie__c m     = getTestMovie();
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

        Assert.isTrue(threw, 'Should throw AuraHandledException for invalid interaction type');
    }

    // -------------------------------------------------------------------------
    // startSwipeSession
    // -------------------------------------------------------------------------

    @IsTest
    static void startSwipeSession_returnsNonBlankId() {
        User   u         = getTestUser();
        String sessionId;

        Test.startTest();
        System.runAs(u) {
            sessionId = UserInteractionService.startSwipeSession();
        }
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(sessionId), 'Session ID should not be blank');
    }

    @IsTest
    static void startSwipeSession_createsSessionRecord() {
        User   u         = getTestUser();
        String sessionId;

        Test.startTest();
        System.runAs(u) {
            sessionId = UserInteractionService.startSwipeSession();
        }
        Test.stopTest();

        List<Swipe_Session__c> sessions = [
            SELECT Id, Owner_User__c, Status__c, Started_At__c
            FROM   Swipe_Session__c
            WHERE  Id = :sessionId
        ];
        Assert.areEqual(1, sessions.size(), 'Should create exactly one Swipe_Session__c record');
        Assert.areEqual(u.Id,    sessions[0].Owner_User__c, 'Owner should be the running user');
        Assert.areEqual('Active', sessions[0].Status__c,    'Status should be Active');
        Assert.isNotNull(sessions[0].Started_At__c,         'Started_At should be populated');
    }

    @IsTest
    static void startSwipeSession_returnsUniqueIds() {
        User   u       = getTestUser();
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
        User     u = getTestUser();
        Movie__c m = getTestMovie();
        String   sessionId;

        System.runAs(u) { sessionId = UserInteractionService.startSwipeSession(); }

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordSwipe(m.Id, 'right', sessionId);
        }
        Test.stopTest();

        List<User_Movie_Interaction__c> results = queryInteractions(u.Id, m.Id, 'Swipe_Right');
        Assert.areEqual(1, results.size(), 'Expected one Swipe_Right record');
        Assert.areEqual(sessionId, results[0].Swipe_Session__c, 'Swipe_Session__c should reference the session');
        Assert.areEqual('Swipe_Session', results[0].Interaction_Source__c, 'Source should be Swipe_Session');
    }

    // -------------------------------------------------------------------------
    // recordSwipe — swipe left
    // -------------------------------------------------------------------------

    @IsTest
    static void recordSwipe_left_insertsSwipeLeft() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();
        String   sessionId;

        System.runAs(u) { sessionId = UserInteractionService.startSwipeSession(); }

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordSwipe(m.Id, 'left', sessionId);
        }
        Test.stopTest();

        List<User_Movie_Interaction__c> results = queryInteractions(u.Id, m.Id, 'Swipe_Left');
        Assert.areEqual(1, results.size(), 'Expected one Swipe_Left record');
        Assert.areEqual(sessionId, results[0].Swipe_Session__c);
    }

    // -------------------------------------------------------------------------
    // recordSwipe — update existing record in same session
    // -------------------------------------------------------------------------

    @IsTest
    static void recordSwipe_sameSession_updatesExistingRecord() {
        User     u = getTestUser();
        Movie__c m = getTestMovie();
        String   sessionId;

        System.runAs(u) {
            sessionId = UserInteractionService.startSwipeSession();
            UserInteractionService.recordSwipe(m.Id, 'left', sessionId);
        }

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.recordSwipe(m.Id, 'right', sessionId);
        }
        Test.stopTest();

        List<User_Movie_Interaction__c> allSwipes = [
            SELECT Id, Interaction_Type__c
            FROM   User_Movie_Interaction__c
            WHERE  User__c          = :u.Id
            AND    Movie__c         = :m.Id
            AND    Swipe_Session__c = :sessionId
        ];
        Assert.areEqual(1, allSwipes.size(), 'Should still be only one record for this session');
        Assert.areEqual('Swipe_Right', allSwipes[0].Interaction_Type__c, 'Direction should be updated to Swipe_Right');
    }

    // -------------------------------------------------------------------------
    // recordSwipe — invalid direction
    // -------------------------------------------------------------------------

    @IsTest
    static void recordSwipe_invalidDirection_throwsException() {
        User     u     = getTestUser();
        Movie__c m     = getTestMovie();
        Boolean  threw = false;
        String   sessionId;

        System.runAs(u) { sessionId = UserInteractionService.startSwipeSession(); }

        Test.startTest();
        System.runAs(u) {
            try {
                UserInteractionService.recordSwipe(m.Id, 'up', sessionId);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Invalid direction should throw AuraHandledException');
    }

    // -------------------------------------------------------------------------
    // recordSwipe — two users, same movie, own sessions: separate records
    // -------------------------------------------------------------------------

    @IsTest
    static void recordSwipe_twoUsers_sameMovie_createSeparateRecords() {
        User     u1 = getTestUser();
        User     u2 = getTestUser2();
        Movie__c m  = getTestMovie();
        String   session1, session2;

        System.runAs(u1) { session1 = UserInteractionService.startSwipeSession(); }
        System.runAs(u2) { session2 = UserInteractionService.startSwipeSession(); }

        Test.startTest();
        System.runAs(u1) { UserInteractionService.recordSwipe(m.Id, 'right', session1); }
        System.runAs(u2) { UserInteractionService.recordSwipe(m.Id, 'right', session2); }
        Test.stopTest();

        List<User_Movie_Interaction__c> allSwipes = [
            SELECT Id, User__c
            FROM   User_Movie_Interaction__c
            WHERE  Movie__c            = :m.Id
            AND    Interaction_Type__c = 'Swipe_Right'
        ];
        Assert.areEqual(2, allSwipes.size(), 'Each user should have their own Swipe_Right record — no collision');

        Set<Id> userIds = new Set<Id>();
        for (User_Movie_Interaction__c rec : allSwipes) {
            userIds.add(rec.User__c);
        }
        Assert.isTrue(userIds.contains(u1.Id), 'User 1 record should exist');
        Assert.isTrue(userIds.contains(u2.Id), 'User 2 record should exist');
    }

    // -------------------------------------------------------------------------
    // getNextSwipeMovie — returns movie when subscription + availability exist
    // -------------------------------------------------------------------------

    @IsTest
    static void getNextSwipeMovie_returnsMovieWithActiveSubscription() {
        User   u = getTestUser();
        String sessionId;

        System.runAs(u) { sessionId = UserInteractionService.startSwipeSession(); }

        Test.startTest();
        Movie__c result;
        System.runAs(u) {
            result = UserInteractionService.getNextSwipeMovie(sessionId);
        }
        Test.stopTest();

        Assert.isNotNull(result, 'Should return a movie when user has active subscriptions');
        Assert.isNotNull(result.Name, 'Movie name should be populated');
    }

    // -------------------------------------------------------------------------
    // getNextSwipeMovie — skips already-swiped movies
    // -------------------------------------------------------------------------

    @IsTest
    static void getNextSwipeMovie_skipsAlreadySwiped() {
        User     u  = getTestUser();
        Movie__c m1 = getTestMovie();
        String   sessionId;

        System.runAs(u) {
            sessionId = UserInteractionService.startSwipeSession();
            // Snapshot the queue and swipe the first movie
            UserInteractionService.getNextSwipeMovie(sessionId);
            UserInteractionService.recordSwipe(m1.Id, 'right', sessionId);
        }

        Test.startTest();
        Movie__c result;
        System.runAs(u) {
            result = UserInteractionService.getNextSwipeMovie(sessionId);
        }
        Test.stopTest();

        Assert.isNotNull(result, 'Should return the second movie after swiping the first');
        Assert.areNotEqual(m1.Id, result.Id, 'Result should not be the already-swiped movie');
    }

    // -------------------------------------------------------------------------
    // getNextSwipeMovie — returns null when deck exhausted
    // -------------------------------------------------------------------------

    @IsTest
    static void getNextSwipeMovie_returnsNullWhenDeckExhausted() {
        User     u  = getTestUser();
        Movie__c m1 = getTestMovie();
        Movie__c m2 = getTestMovie2();
        String   sessionId;

        System.runAs(u) {
            sessionId = UserInteractionService.startSwipeSession();
            UserInteractionService.getNextSwipeMovie(sessionId);
            UserInteractionService.recordSwipe(m1.Id, 'right', sessionId);
            UserInteractionService.recordSwipe(m2.Id, 'left',  sessionId);
        }

        Test.startTest();
        Movie__c result;
        System.runAs(u) {
            result = UserInteractionService.getNextSwipeMovie(sessionId);
        }
        Test.stopTest();

        Assert.isNull(result, 'Should return null when all movies have been swiped');
    }

    // -------------------------------------------------------------------------
    // getNextSwipeMovie — returns null when no subscriptions
    // -------------------------------------------------------------------------

    @IsTest
    static void getNextSwipeMovie_returnsNullWithNoSubscriptions() {
        // testUser2 has no subscriptions seeded in @TestSetup
        User   u = getTestUser2();
        String sessionId;

        System.runAs(u) { sessionId = UserInteractionService.startSwipeSession(); }

        Test.startTest();
        Movie__c result;
        System.runAs(u) {
            result = UserInteractionService.getNextSwipeMovie(sessionId);
        }
        Test.stopTest();

        Assert.isNull(result, 'Should return null when user has no active subscriptions');
    }

    // -------------------------------------------------------------------------
    // endSwipeSession — marks session Completed
    // -------------------------------------------------------------------------

    @IsTest
    static void endSwipeSession_marksSessionCompleted() {
        User   u = getTestUser();
        String sessionId;

        System.runAs(u) { sessionId = UserInteractionService.startSwipeSession(); }

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.endSwipeSession(sessionId);
        }
        Test.stopTest();

        Swipe_Session__c s = [
            SELECT Status__c, Ended_At__c
            FROM   Swipe_Session__c
            WHERE  Id = :sessionId
        ];
        Assert.areEqual('Completed', s.Status__c, 'Status should be Completed');
        Assert.isNotNull(s.Ended_At__c,            'Ended_At should be stamped');
    }

    // -------------------------------------------------------------------------
    // endSwipeSession — returns correct swipe counts
    // -------------------------------------------------------------------------

    @IsTest
    static void endSwipeSession_returnsSummaryWithCorrectCounts() {
        User     u  = getTestUser();
        Movie__c m1 = getTestMovie();
        Movie__c m2 = getTestMovie2();
        String   sessionId;

        System.runAs(u) {
            sessionId = UserInteractionService.startSwipeSession();
            UserInteractionService.recordSwipe(m1.Id, 'right', sessionId);
            UserInteractionService.recordSwipe(m2.Id, 'left',  sessionId);
        }

        Test.startTest();
        UserInteractionService.SwipeSessionSummaryDto dto;
        System.runAs(u) {
            dto = UserInteractionService.endSwipeSession(sessionId);
        }
        Test.stopTest();

        Assert.isNotNull(dto, 'DTO should not be null');
        Assert.areEqual(1, dto.swipedRight, 'Should count 1 Swipe_Right');
        Assert.areEqual(1, dto.swipedLeft,  'Should count 1 Swipe_Left');
        Assert.areEqual(0, dto.matchCount,  'matchCount should be 0 in Phase 2');
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

        Set<String> returnedTypes = new Set<String>();
        for (UserInteractionService.InteractionDto dto : dtos) {
            returnedTypes.add(dto.interactionType);
            Assert.areEqual(m.Id, dto.movieId,       'movieId on DTO should match');
            Assert.isNotNull(dto.interactionId,      'interactionId should be populated');
            Assert.isNotNull(dto.interactionDateTime,'interactionDateTime should be populated');
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

        Assert.areEqual(1, queryInteractions(u.Id, m.Id, 'Thumbs_Up').size(), 'Record should exist before clearInteraction');

        Test.startTest();
        System.runAs(u) {
            UserInteractionService.clearInteraction(m.Id, 'Thumbs_Up');
        }
        Test.stopTest();

        Assert.areEqual(0, queryInteractions(u.Id, m.Id, 'Thumbs_Up').size(), 'Record should be deleted after clearInteraction');
    }

    @IsTest
    static void clearInteraction_noOpWhenRecordDoesNotExist() {
        User     u     = getTestUser();
        Movie__c m     = getTestMovie();
        Boolean  threw = false;

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

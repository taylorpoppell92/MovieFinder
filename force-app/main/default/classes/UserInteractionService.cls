public with sharing class UserInteractionService {

    // -------------------------------------------------------------------------
    // DTOs
    // -------------------------------------------------------------------------

    public class InteractionDto {
        @AuraEnabled public String   interactionId;
        @AuraEnabled public String   movieId;
        @AuraEnabled public String   interactionType;
        @AuraEnabled public String   source;
        @AuraEnabled public String   swipeSessionId;
        @AuraEnabled public Datetime interactionDateTime;
    }

    public class SwipeSessionSummaryDto {
        @AuraEnabled public Integer swipedRight = 0;
        @AuraEnabled public Integer swipedLeft  = 0;
        @AuraEnabled public Integer matchCount  = 0; // Phase 3: populated by MatchDetectionService
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    private static final Set<String> VALID_RATING_TYPES = new Set<String>{
        'Thumbs_Up', 'Thumbs_Down', 'Watchlisted', 'Watched'
    };

    private static final Map<String, String> OPPOSITE_THUMB = new Map<String, String>{
        'Thumbs_Up'   => 'Thumbs_Down',
        'Thumbs_Down' => 'Thumbs_Up'
    };

    // -------------------------------------------------------------------------
    // recordInteraction
    // -------------------------------------------------------------------------

    /**
     * Records a user interaction (Thumbs_Up, Thumbs_Down, Watchlisted, Watched).
     * Calling twice for the same movie + type toggles the record off (delete).
     * Thumbs_Up and Thumbs_Down are mutually exclusive per movie.
     */
    @AuraEnabled(cacheable=false)
    public static void recordInteraction(
        String movieId,
        String interactionType,
        String source
    ) {
        if (String.isBlank(movieId) || String.isBlank(interactionType)) {
            throw new AuraHandledException(
                'movieId and interactionType are required.'
            );
        }

        if (!VALID_RATING_TYPES.contains(interactionType)) {
            throw new AuraHandledException(
                'Invalid interaction type: ' + interactionType
                + '. Must be one of: ' + String.join(new List<String>(VALID_RATING_TYPES), ', ')
            );
        }

        String userId = UserInfo.getUserId();

        String oppositeType = OPPOSITE_THUMB.get(interactionType);
        Set<String> typesToQuery = new Set<String>{ interactionType };
        if (oppositeType != null) {
            typesToQuery.add(oppositeType);
        }

        List<User_Movie_Interaction__c> existing = [
            SELECT Id, Interaction_Type__c
            FROM   User_Movie_Interaction__c
            WHERE  User__c             = :userId
            AND    Movie__c            = :movieId
            AND    Interaction_Type__c IN :typesToQuery
            WITH USER_MODE
        ];

        User_Movie_Interaction__c matchedRecord  = null;
        User_Movie_Interaction__c oppositeRecord = null;

        for (User_Movie_Interaction__c rec : existing) {
            if (rec.Interaction_Type__c == interactionType) {
                matchedRecord = rec;
            } else {
                oppositeRecord = rec;
            }
        }

        if (oppositeRecord != null) {
            delete oppositeRecord;
        }

        if (matchedRecord != null) {
            delete matchedRecord;
        } else {
            insert new User_Movie_Interaction__c(
                User__c                 = userId,
                Movie__c                = movieId,
                Interaction_Type__c     = interactionType,
                Interaction_Source__c   = source,
                Interaction_DateTime__c = Datetime.now()
            );
        }
    }

    // -------------------------------------------------------------------------
    // startSwipeSession
    // -------------------------------------------------------------------------

    /**
     * Creates a Swipe_Session__c record for the current user and returns its Id.
     * The LWC holds this Id for the session lifetime and passes it to recordSwipe.
     */
    @AuraEnabled(cacheable=false)
    public static String startSwipeSession() {
        Swipe_Session__c session = new Swipe_Session__c(
            Owner_User__c = UserInfo.getUserId(),
            Status__c     = 'Active',
            Started_At__c = Datetime.now()
        );
        insert session;
        return session.Id;
    }

    // -------------------------------------------------------------------------
    // recordSwipe
    // -------------------------------------------------------------------------

    /**
     * Records a swipe left or right within a swipe session.
     * If the user swipes the same card again in the same session, the direction
     * is updated rather than inserting a duplicate.
     */
    @AuraEnabled(cacheable=false)
    public static void recordSwipe(
        String movieId,
        String direction,
        String sessionId
    ) {
        String interactionType;
        if (direction == 'right') {
            interactionType = 'Swipe_Right';
        } else if (direction == 'left') {
            interactionType = 'Swipe_Left';
        } else {
            throw new AuraHandledException(
                'Invalid swipe direction: ' + direction + '. Must be "left" or "right".'
            );
        }

        String userId = UserInfo.getUserId();

        List<User_Movie_Interaction__c> existing = [
            SELECT Id
            FROM   User_Movie_Interaction__c
            WHERE  User__c          = :userId
            AND    Movie__c         = :movieId
            AND    Swipe_Session__c = :sessionId
            WITH USER_MODE
            LIMIT 1
        ];

        if (!existing.isEmpty()) {
            User_Movie_Interaction__c rec = existing[0];
            rec.Interaction_Type__c     = interactionType;
            rec.Interaction_DateTime__c = Datetime.now();
            update rec;
        } else {
            insert new User_Movie_Interaction__c(
                User__c                 = userId,
                Movie__c                = movieId,
                Interaction_Type__c     = interactionType,
                Interaction_Source__c   = 'Swipe_Session',
                Interaction_DateTime__c = Datetime.now(),
                Swipe_Session__c        = sessionId
            );
        }
    }

    // -------------------------------------------------------------------------
    // getNextSwipeMovie
    // -------------------------------------------------------------------------

    /**
     * Returns the next Movie__c the user has not yet swiped in this session.
     * On the first call the eligible movie set is snapshotted (ordered by
     * TMDB_Popularity__c desc) into Swipe_Session__c.Movie_Queue__c so that
     * subsequent calls are cheap and the queue is stable for the session lifetime.
     * Returns null when the deck is exhausted.
     */
    @AuraEnabled(cacheable=false)
    public static Movie__c getNextSwipeMovie(String sessionId) {
        Swipe_Session__c session = [
            SELECT Id, Movie_Queue__c, Owner_User__c
            FROM   Swipe_Session__c
            WHERE  Id = :sessionId
            WITH USER_MODE
            LIMIT 1
        ];

        List<String> queue = String.isBlank(session.Movie_Queue__c)
            ? buildAndSnapshotQueue(session)
            : (List<String>) JSON.deserialize(session.Movie_Queue__c, List<String>.class);

        Set<String> swiped = new Set<String>();
        for (User_Movie_Interaction__c rec : [
            SELECT Movie__c
            FROM   User_Movie_Interaction__c
            WHERE  Swipe_Session__c = :sessionId
            AND    User__c          = :UserInfo.getUserId()
            WITH USER_MODE
        ]) {
            swiped.add(rec.Movie__c);
        }

        Id nextMovieId;
        for (String movieId : queue) {
            if (!swiped.contains(movieId)) {
                nextMovieId = movieId;
                break;
            }
        }

        if (nextMovieId == null) {
            return null;
        }

        return [
            SELECT Id, Name, Poster_URL__c, Backdrop_URL__c,
                   Release_Year__c, Overview__c, Genre_Tags__c,
                   Runtime_Minutes__c, Aggregate_Rating__c, Content_Rating__c,
                   TMDB_Popularity__c
            FROM   Movie__c
            WHERE  Id = :nextMovieId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    private static List<String> buildAndSnapshotQueue(Swipe_Session__c session) {
        Set<Id> serviceIds = new Set<Id>();
        for (User_Subscription__c sub : [
            SELECT Streaming_Service__c
            FROM   User_Subscription__c
            WHERE  User__c      = :session.Owner_User__c
            AND    Is_Active__c = true
            WITH USER_MODE
        ]) {
            serviceIds.add(sub.Streaming_Service__c);
        }

        List<String> queue = new List<String>();

        if (!serviceIds.isEmpty()) {
            for (Movie__c movie : [
                SELECT Id
                FROM   Movie__c
                WHERE  Id IN (
                    SELECT Movie__c
                    FROM   Movie_Availability__c
                    WHERE  Streaming_Service__c IN :serviceIds
                    AND    Availability_Type__c  = 'Subscription'
                )
                WITH USER_MODE
                ORDER BY TMDB_Popularity__c DESC NULLS LAST
                LIMIT  500
            ]) {
                queue.add(movie.Id);
            }
        }

        session.Movie_Queue__c = JSON.serialize(queue);
        update session;
        return queue;
    }

    // -------------------------------------------------------------------------
    // endSwipeSession
    // -------------------------------------------------------------------------

    /**
     * Marks the session Completed, stamps Ended_At, and returns a summary.
     * matchCount is always 0 in Phase 2 — Phase 3 wires MatchDetectionService here.
     */
    @AuraEnabled(cacheable=false)
    public static SwipeSessionSummaryDto endSwipeSession(String sessionId) {
        Swipe_Session__c session = [
            SELECT Id
            FROM   Swipe_Session__c
            WHERE  Id = :sessionId
            WITH USER_MODE
            LIMIT 1
        ];
        session.Status__c   = 'Completed';
        session.Ended_At__c = Datetime.now();
        update session;

        SwipeSessionSummaryDto dto = new SwipeSessionSummaryDto();
        for (AggregateResult row : [
            SELECT Interaction_Type__c type, COUNT(Id) cnt
            FROM   User_Movie_Interaction__c
            WHERE  Swipe_Session__c = :sessionId
            AND    User__c          = :UserInfo.getUserId()
            GROUP BY Interaction_Type__c
        ]) {
            String t  = (String)  row.get('type');
            Integer c = Integer.valueOf(row.get('cnt'));
            if (t == 'Swipe_Right') dto.swipedRight = c;
            if (t == 'Swipe_Left')  dto.swipedLeft  = c;
        }
        return dto;
    }

    // -------------------------------------------------------------------------
    // getUserInteractions
    // -------------------------------------------------------------------------

    @AuraEnabled(cacheable=true)
    public static List<InteractionDto> getUserInteractions(String movieId) {
        List<User_Movie_Interaction__c> records = [
            SELECT Id,
                   Movie__c,
                   Interaction_Type__c,
                   Interaction_Source__c,
                   Swipe_Session__c,
                   Interaction_DateTime__c
            FROM   User_Movie_Interaction__c
            WHERE  User__c  = :UserInfo.getUserId()
            AND    Movie__c = :movieId
            WITH USER_MODE
            ORDER BY Interaction_DateTime__c DESC
        ];

        List<InteractionDto> dtos = new List<InteractionDto>();
        for (User_Movie_Interaction__c rec : records) {
            InteractionDto dto      = new InteractionDto();
            dto.interactionId       = rec.Id;
            dto.movieId             = rec.Movie__c;
            dto.interactionType     = rec.Interaction_Type__c;
            dto.source              = rec.Interaction_Source__c;
            dto.swipeSessionId      = rec.Swipe_Session__c;
            dto.interactionDateTime = rec.Interaction_DateTime__c;
            dtos.add(dto);
        }
        return dtos;
    }

    // -------------------------------------------------------------------------
    // clearInteraction
    // -------------------------------------------------------------------------

    @AuraEnabled(cacheable=false)
    public static void clearInteraction(String movieId, String interactionType) {
        List<User_Movie_Interaction__c> toDelete = [
            SELECT Id
            FROM   User_Movie_Interaction__c
            WHERE  User__c             = :UserInfo.getUserId()
            AND    Movie__c            = :movieId
            AND    Interaction_Type__c = :interactionType
            WITH USER_MODE
            LIMIT 1
        ];

        if (!toDelete.isEmpty()) {
            delete toDelete;
        }
    }
}

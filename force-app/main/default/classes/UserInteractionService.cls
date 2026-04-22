public with sharing class UserInteractionService {

    // -------------------------------------------------------------------------
    // DTO
    // -------------------------------------------------------------------------

    public class InteractionDto {
        @AuraEnabled public String   interactionId;
        @AuraEnabled public String   movieId;
        @AuraEnabled public String   interactionType;
        @AuraEnabled public String   source;
        @AuraEnabled public String   swipeSessionId;
        @AuraEnabled public Datetime interactionDateTime;
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    private static final Set<String> VALID_RATING_TYPES = new Set<String>{
        'Thumbs_Up', 'Thumbs_Down', 'Watchlisted', 'Watched'
    };

    // The two types that are mutually exclusive with each other per movie
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

        // Query for the requested type AND its opposite (if applicable) in one round trip
        String oppositeType = OPPOSITE_THUMB.get(interactionType);
        Set<String> typesToQuery = new Set<String>{ interactionType };
        if (oppositeType != null) {
            typesToQuery.add(oppositeType);
        }

        List<User_Movie_Interaction__c> existing = [
            SELECT Id, Interaction_Type__c
            FROM   User_Movie_Interaction__c
            WHERE  User__c              = :userId
            AND    Movie__c             = :movieId
            AND    Interaction_Type__c  IN :typesToQuery
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

        // Delete the opposite thumb before anything else (mutual exclusivity)
        if (oppositeRecord != null) {
            delete oppositeRecord;
        }

        if (matchedRecord != null) {
            // Toggle off — user un-selected the same type they already had
            delete matchedRecord;
        } else {
            // Insert new interaction
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
     * Generates a UUID-style session ID for a swipe session.
     * The LWC stamps this on each recordSwipe call so swipes can be grouped.
     */
    @AuraEnabled(cacheable=false)
    public static String startSwipeSession() {
        // AES-128 key gives us 32 hex chars; we need 36 to fill the field.
        // Use two key segments and concatenate to get enough entropy, then truncate.
        String hex = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        // hex is 32 chars. Pad to 36 by appending 4 more chars from a second key.
        String hex2 = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        return (hex + hex2).substring(0, 36);
    }

    // -------------------------------------------------------------------------
    // recordSwipe
    // -------------------------------------------------------------------------

    /**
     * Records a swipe left or right within a swipe session.
     * Uses a composite check (User + Movie + SwipeSessionId) to prevent duplicates
     * while still allowing the interaction to be updated if the user swipes again
     * on the same card in the same session.
     */
    @AuraEnabled(cacheable=false)
    public static void recordSwipe(
        String movieId,
        String direction,
        String swipeSessionId
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
            WHERE  User__c             = :userId
            AND    Movie__c            = :movieId
            AND    Swipe_Session_Id__c = :swipeSessionId
            WITH USER_MODE
            LIMIT 1
        ];

        if (!existing.isEmpty()) {
            // Update the existing record in case direction changed within the session
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
                Swipe_Session_Id__c     = swipeSessionId
            );
        }
    }

    // -------------------------------------------------------------------------
    // getUserInteractions
    // -------------------------------------------------------------------------

    /**
     * Returns all interactions the current user has recorded for a given movie.
     * Cacheable — safe because it only ever returns data for the running user.
     */
    @AuraEnabled(cacheable=true)
    public static List<InteractionDto> getUserInteractions(String movieId) {
        List<User_Movie_Interaction__c> records = [
            SELECT Id,
                   Movie__c,
                   Interaction_Type__c,
                   Interaction_Source__c,
                   Swipe_Session_Id__c,
                   Interaction_DateTime__c
            FROM   User_Movie_Interaction__c
            WHERE  User__c  = :UserInfo.getUserId()
            AND    Movie__c = :movieId
            WITH USER_MODE
            ORDER BY Interaction_DateTime__c DESC
        ];

        List<InteractionDto> dtos = new List<InteractionDto>();
        for (User_Movie_Interaction__c rec : records) {
            InteractionDto dto       = new InteractionDto();
            dto.interactionId        = rec.Id;
            dto.movieId              = rec.Movie__c;
            dto.interactionType      = rec.Interaction_Type__c;
            dto.source               = rec.Interaction_Source__c;
            dto.swipeSessionId       = rec.Swipe_Session_Id__c;
            dto.interactionDateTime  = rec.Interaction_DateTime__c;
            dtos.add(dto);
        }
        return dtos;
    }

    // -------------------------------------------------------------------------
    // clearInteraction
    // -------------------------------------------------------------------------

    /**
     * Explicitly removes a single interaction type for the current user + movie.
     * No-op if the record does not exist.
     */
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
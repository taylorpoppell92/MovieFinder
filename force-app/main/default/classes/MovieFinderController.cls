public with sharing class MovieFinderController {

    // ─────────────────────────────────────────────────────────────────────────
    // DTOs
    // ─────────────────────────────────────────────────────────────────────────

    public class MovieDto {
        @AuraEnabled public String  movieId;
        @AuraEnabled public String  tmdbId;
        @AuraEnabled public String  title;
        @AuraEnabled public String  posterUrl;
        @AuraEnabled public String  backdropUrl;
        @AuraEnabled public Integer releaseYear;
        @AuraEnabled public String  genreTags;
        @AuraEnabled public Integer runtimeMinutes;
        @AuraEnabled public String  contentRating;
        @AuraEnabled public Decimal aggregateRating;
        @AuraEnabled public String  overview;
        @AuraEnabled public String  existingInteraction; // null if none, else Interaction_Type__c value
        @AuraEnabled public List<String> availableOnServiceIds; // Streaming_Service__c Ids
    }

    public class SubscriptionDto {
        @AuraEnabled public String  subscriptionId;
        @AuraEnabled public String  serviceId;
        @AuraEnabled public String  serviceName;
        @AuraEnabled public String  logoUrl;
        @AuraEnabled public Integer tmdbProviderId;
        @AuraEnabled public Boolean isActive;
    }

    public class StreamingServiceDto {
        @AuraEnabled public String  serviceId;
        @AuraEnabled public String  serviceName;
        @AuraEnabled public String  serviceKey;
        @AuraEnabled public String  logoUrl;
        @AuraEnabled public Integer tmdbProviderId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // READ METHODS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns a paginated list of movies available on the current user's active
     * subscriptions.  Results are ordered by TMDB popularity descending.
     *
     * Two-step approach for the availability filter:
     *   Step 1 – collect eligible Movie Ids from Movie_Availability__c
     *   Step 2 – query Movie__c IN those Ids
     * This avoids a semi-join subquery which can hit row-count governor limits
     * on large data volumes and prevents subquery row limits from masking results.
     *
     * @param pageNumber  1-based page index
     * @param pageSize    records per page; capped at 50
     * @param serviceFilter  optional Streaming_Service__c Id to narrow results
     */
    @AuraEnabled(cacheable=true)
    public static List<MovieDto> getAvailableMovies(
        Integer pageNumber,
        Integer pageSize,
        String  serviceFilter
    ) {
        try {
            // ── 1. Validate / sanitise pagination inputs ──────────────────────
            Integer safePageSize   = (pageSize   == null || pageSize   < 1) ? 20 : Math.min(pageSize, 50);
            Integer safePageNumber = (pageNumber == null || pageNumber < 1) ? 1  : pageNumber;
            Integer offsetVal      = (safePageNumber - 1) * safePageSize;

            // ── 2. Resolve the user's active subscriptions ────────────────────
            Id userId = UserInfo.getUserId();

            List<User_Subscription__c> subs = [
                SELECT Streaming_Service__c
                FROM   User_Subscription__c
                WHERE  User__c      = :userId
                AND    Is_Active__c = true
            ];

            Set<Id> subscribedServiceIds = new Set<Id>();
            for (User_Subscription__c sub : subs) {
                subscribedServiceIds.add(sub.Streaming_Service__c);
            }

            // Apply optional service filter — if the user doesn't actually
            // subscribe to that service, the resulting set will be empty and
            // the query will safely return no rows.
            if (String.isNotBlank(serviceFilter)) {
                Id filterId = (Id) serviceFilter;
                if (subscribedServiceIds.contains(filterId)) {
                    subscribedServiceIds = new Set<Id>{ filterId };
                } else {
                    subscribedServiceIds = new Set<Id>(); // not subscribed → no results
                }
            }

            if (subscribedServiceIds.isEmpty()) {
                return new List<MovieDto>();
            }

            // ── 3. Step 1: collect Movie Ids from Movie_Availability__c ───────
            // Querying the junction object first keeps the Movie__c query simple
            // and avoids an IN-subquery that counts against the 50k row limit.
            List<Movie_Availability__c> availabilities = [
                SELECT Movie__c, Streaming_Service__c
                FROM   Movie_Availability__c
                WHERE  Streaming_Service__c IN :subscribedServiceIds
                AND    Availability_Type__c  = 'Subscription'
            ];

            // Build a map: Movie Id → list of service Ids (for availableOnServiceIds)
            Map<Id, List<String>> movieToServiceIds = new Map<Id, List<String>>();
            for (Movie_Availability__c ma : availabilities) {
                if (!movieToServiceIds.containsKey(ma.Movie__c)) {
                    movieToServiceIds.put(ma.Movie__c, new List<String>());
                }
                movieToServiceIds.get(ma.Movie__c).add(ma.Streaming_Service__c);
            }

            Set<Id> eligibleMovieIds = movieToServiceIds.keySet();
            if (eligibleMovieIds.isEmpty()) {
                return new List<MovieDto>();
            }

            // ── 4. Step 2: query Movie__c with pagination ─────────────────────
            List<Movie__c> movies = [
                SELECT Id, Name, TMDB_Id__c, Poster_URL__c, Backdrop_URL__c,
                       Release_Year__c, Genre_Tags__c, Runtime_Minutes__c,
                       Content_Rating__c, Aggregate_Rating__c, Overview__c,
                       TMDB_Popularity__c
                FROM   Movie__c
                WHERE  Id IN :eligibleMovieIds
                ORDER BY TMDB_Popularity__c DESC NULLS LAST
                LIMIT  :safePageSize
                OFFSET :offsetVal
            ];

            if (movies.isEmpty()) {
                return new List<MovieDto>();
            }

            // ── 5. Fetch any existing interactions for this user ──────────────
            Set<Id> movieIdSet = new Map<Id, Movie__c>(movies).keySet();
            List<User_Movie_Interaction__c> interactions = [
                SELECT Movie__c, Interaction_Type__c
                FROM   User_Movie_Interaction__c
                WHERE  User__c   = :userId
                AND    Movie__c  IN :movieIdSet
                ORDER BY Interaction_DateTime__c DESC
            ];

            // Keep only the most-recent interaction per movie
            Map<Id, String> movieToInteraction = new Map<Id, String>();
            for (User_Movie_Interaction__c umi : interactions) {
                if (!movieToInteraction.containsKey(umi.Movie__c)) {
                    movieToInteraction.put(umi.Movie__c, umi.Interaction_Type__c);
                }
            }

            // ── 6. Build DTOs ─────────────────────────────────────────────────
            List<MovieDto> results = new List<MovieDto>();
            for (Movie__c m : movies) {
                MovieDto dto          = new MovieDto();
                dto.movieId           = m.Id;
                dto.tmdbId            = m.TMDB_Id__c;
                dto.title             = m.Name;
                dto.posterUrl         = m.Poster_URL__c;
                dto.backdropUrl       = m.Backdrop_URL__c;
                dto.releaseYear       = (m.Release_Year__c != null)
                                            ? Integer.valueOf(m.Release_Year__c)
                                            : null;
                dto.genreTags         = m.Genre_Tags__c;
                dto.runtimeMinutes    = (m.Runtime_Minutes__c != null)
                                            ? Integer.valueOf(m.Runtime_Minutes__c)
                                            : null;
                dto.contentRating     = m.Content_Rating__c;
                dto.aggregateRating   = m.Aggregate_Rating__c;
                dto.overview          = m.Overview__c;
                dto.existingInteraction     = movieToInteraction.get(m.Id);
                dto.availableOnServiceIds   = movieToServiceIds.get(m.Id);
                results.add(dto);
            }

            return results;

        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(
                'getAvailableMovies failed: ' + e.getMessage()
            );
        }
    }

    /**
     * Returns all active streaming service subscriptions for the current user,
     * including service metadata needed by the UI (name, logo, provider id).
     */
    @AuraEnabled(cacheable=true)
    public static List<SubscriptionDto> getUserSubscriptions() {
        try {
            Id userId = UserInfo.getUserId();

            List<User_Subscription__c> subs = [
                SELECT Id, Is_Active__c, Verified_At__c,
                       Streaming_Service__c,
                       Streaming_Service__r.Name,
                       Streaming_Service__r.Logo_URL__c,
                       Streaming_Service__r.TMDB_Provider_Id__c
                FROM   User_Subscription__c
                WHERE  User__c      = :userId
                AND    Is_Active__c = true
                ORDER BY Streaming_Service__r.Name ASC
            ];

            List<SubscriptionDto> results = new List<SubscriptionDto>();
            for (User_Subscription__c sub : subs) {
                SubscriptionDto dto  = new SubscriptionDto();
                dto.subscriptionId   = sub.Id;
                dto.serviceId        = sub.Streaming_Service__c;
                dto.serviceName      = sub.Streaming_Service__r.Name;
                dto.logoUrl          = sub.Streaming_Service__r.Logo_URL__c;
                dto.tmdbProviderId   = (sub.Streaming_Service__r.TMDB_Provider_Id__c != null)
                                           ? Integer.valueOf(sub.Streaming_Service__r.TMDB_Provider_Id__c)
                                           : null;
                dto.isActive         = sub.Is_Active__c;
                results.add(dto);
            }

            return results;

        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(
                'getUserSubscriptions failed: ' + e.getMessage()
            );
        }
    }

    /**
     * Returns every active streaming service — used to populate the
     * subscription-management UI so users can add/remove services.
     */
    @AuraEnabled(cacheable=true)
    public static List<StreamingServiceDto> getAllStreamingServices() {
        try {
            List<Streaming_Service__c> services = [
                SELECT Id, Name, Service_Key__c, Logo_URL__c, TMDB_Provider_Id__c
                FROM   Streaming_Service__c
                WHERE  Is_Active__c = true
                ORDER BY Name ASC
            ];

            List<StreamingServiceDto> results = new List<StreamingServiceDto>();
            for (Streaming_Service__c svc : services) {
                StreamingServiceDto dto = new StreamingServiceDto();
                dto.serviceId        = svc.Id;
                dto.serviceName      = svc.Name;
                dto.serviceKey       = svc.Service_Key__c;
                dto.logoUrl          = svc.Logo_URL__c;
                dto.tmdbProviderId   = (svc.TMDB_Provider_Id__c != null)
                                           ? Integer.valueOf(svc.TMDB_Provider_Id__c)
                                           : null;
                results.add(dto);
            }

            return results;

        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(
                'getAllStreamingServices failed: ' + e.getMessage()
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // WRITE METHODS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Creates or updates a User_Subscription__c for the current user.
     *
     * Pattern: query-then-upsert rather than a Database.upsert with an external
     * id, because User__c + Streaming_Service__c is a composite key that
     * Salesforce doesn't expose as a native upsert key unless you define a
     * custom unique index.  This keeps the logic explicit and easy to extend.
     *
     * With sharing is enforced at the class level, so users cannot touch
     * subscription records they don't own.
     *
     * @param streamingServiceId  Id of the Streaming_Service__c to subscribe/unsubscribe
     * @param isActive            true = subscribe, false = unsubscribe
     */
    @AuraEnabled(cacheable=false)
    public static void upsertUserSubscription(String streamingServiceId, Boolean isActive) {
        try {
            if (String.isBlank(streamingServiceId)) {
                throw new AuraHandledException('streamingServiceId is required.');
            }

            Id userId    = UserInfo.getUserId();
            Id serviceId = (Id) streamingServiceId;

            List<User_Subscription__c> existing = [
                SELECT Id, Is_Active__c
                FROM   User_Subscription__c
                WHERE  User__c              = :userId
                AND    Streaming_Service__c = :serviceId
                LIMIT  1
            ];

            if (!existing.isEmpty()) {
                // Update the existing record
                existing[0].Is_Active__c = isActive;
                update existing[0];
            } else {
                // Insert a brand-new subscription
                User_Subscription__c newSub = new User_Subscription__c(
                    User__c              = userId,
                    Streaming_Service__c = serviceId,
                    Is_Active__c         = isActive,
                    Verified_At__c       = System.now()
                );
                insert newSub;
            }

        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(
                'upsertUserSubscription failed: ' + e.getMessage()
            );
        }
    }
}

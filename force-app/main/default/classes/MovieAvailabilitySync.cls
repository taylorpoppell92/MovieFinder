public class MovieAvailabilitySync implements Queueable, Database.AllowsCallouts {

    private Id streamingServiceId;
    private Integer page;

    // TMDB returns exactly 20 results per page when there are more pages to fetch
    private static final Integer TMDB_PAGE_SIZE = 20;
    // TMDB hard cap — querying beyond this returns no results
    private static final Integer TMDB_MAX_PAGE = 500;

    public MovieAvailabilitySync(Id streamingServiceId, Integer page) {
        this.streamingServiceId = streamingServiceId;
        this.page = page;
    }

    public void execute(QueueableContext ctx) {
        try {
            // Step 1: Load the service record so we have the TMDB provider ID
            Streaming_Service__c service = [
                SELECT Id, Name, TMDB_Provider_Id__c
                FROM Streaming_Service__c
                WHERE Id = :streamingServiceId
                LIMIT 1
            ];

            System.debug('###service: ' + service);
            // Step 2: Discover movies for this provider/page
            List<TmdbApiService.MovieResult> results =
                TmdbApiService.discoverMoviesByProvider(
                    (Integer) service.TMDB_Provider_Id__c,
                    page
                );

            System.debug('###results: ' + results);
            // Step 3: Nothing came back — we have consumed all pages, stop chaining
            if (results == null || results.isEmpty()) {
                System.debug(
                    'MovieAvailabilitySync: no results for provider '
                    + service.TMDB_Provider_Id__c
                    + ' page ' + page + '. Stopping.'
                );
                return;
            }

            // Step 4: Build Movie__c sObjects and upsert on the external ID
            List<Movie__c> movies = new List<Movie__c>();
            for (TmdbApiService.MovieResult r : results) {
                movies.add(new Movie__c(
                    TMDB_Id__c          = r.tmdbId,
                    Name                = r.title,
                    Poster_URL__c       = r.posterPath,
                    Backdrop_URL__c     = r.backdropPath,
                    Release_Year__c     = r.releaseYear,
                    Genre_Tags__c       = r.genreTags,
                    Runtime_Minutes__c  = r.runtimeMinutes,
                    Aggregate_Rating__c = r.voteAverage,
                    Overview__c         = r.overview,
                    TMDB_Popularity__c  = r.popularity,
                    Last_Synced__c      = Datetime.now()
                ));
            }
            
            System.debug('###movies: ' + movies);
            // allOrNone=false: a single malformed record won't roll back the rest
            Database.upsert(movies, Movie__c.TMDB_Id__c, false);

            // Step 5: Re-query to get Salesforce record Ids — the upsert result
            // objects don't carry field values, so we go back to the DB
            Set<String> tmdbIds = new Set<String>();
            for (TmdbApiService.MovieResult r : results) {
                tmdbIds.add(r.tmdbId);
            }

            Map<String, Id> tmdbIdToSfId = new Map<String, Id>();
            for (Movie__c m : [
                SELECT Id, TMDB_Id__c
                FROM Movie__c
                WHERE TMDB_Id__c IN :tmdbIds
            ]) {
                tmdbIdToSfId.put(m.TMDB_Id__c, m.Id);
            }

            // Step 6 & 7: Build availability records with a manual query+merge
            // so we avoid the composite external ID complexity on Movie_Availability__c.
            // First, pull any existing availability rows for this service+movie set.
            Map<Id, Movie_Availability__c> existingByMovieId = new Map<Id, Movie_Availability__c>();
            for (Movie_Availability__c existing : [
                SELECT Id, Movie__c, Streaming_Service__c, Availability_Type__c, Available_As_Of__c
                FROM Movie_Availability__c
                WHERE Streaming_Service__c = :streamingServiceId
                  AND Movie__c IN :tmdbIdToSfId.values()
            ]) {
                existingByMovieId.put(existing.Movie__c, existing);
            }

            List<Movie_Availability__c> toUpsertAvailability = new List<Movie_Availability__c>();
            Datetime now = Datetime.now();

            for (TmdbApiService.MovieResult r : results) {
                Id movieSfId = tmdbIdToSfId.get(r.tmdbId);
                if (movieSfId == null) {
                    // Upsert failed for this record — skip availability row
                    continue;
                }

                Movie_Availability__c avail;
                if (existingByMovieId.containsKey(movieSfId)) {
                    // Update in place — keep the existing record Id
                    avail = existingByMovieId.get(movieSfId);
                } else {
                    avail = new Movie_Availability__c(
                        Movie__c            = movieSfId,
                        Streaming_Service__c = streamingServiceId
                    );
                }
                avail.Availability_Type__c = 'Subscription';
                avail.Available_As_Of__c   = now;
                toUpsertAvailability.add(avail);
            }

            // Records with a populated Id field will be updated; without Id, inserted
            Database.upsert(toUpsertAvailability, false);

            // Step 8: Chain the next page if TMDB signaled there are more results
            // and we haven't hit the TMDB page cap
            if (results.size() == TMDB_PAGE_SIZE && page < TMDB_MAX_PAGE) {
                System.enqueueJob(new MovieAvailabilitySync(streamingServiceId, page + 1));
            }

        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                'MovieAvailabilitySync failed for serviceId=' + streamingServiceId
                + ' page=' + page + ' | ' + e.getTypeName()
                + ': ' + e.getMessage()
                + '\n' + e.getStackTraceString()
            );
        }
    }
}
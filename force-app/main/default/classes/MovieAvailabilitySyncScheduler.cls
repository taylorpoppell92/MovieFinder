// Nightly entry point for the MovieFinder availability sync.
// Schedule via:
//   System.schedule('MovieFinder Nightly Sync', '0 0 2 * * ?', new MovieAvailabilitySyncScheduler());
global class MovieAvailabilitySyncScheduler implements Schedulable {

    global void execute(SchedulableContext ctx) {
        try {
            List<Streaming_Service__c> activeServices = [
                SELECT Id, Name, TMDB_Provider_Id__c
                FROM Streaming_Service__c
                WHERE Is_Active__c = TRUE
                  AND TMDB_Provider_Id__c != NULL
            ];

            if (activeServices.isEmpty()) {
                System.debug('MovieAvailabilitySyncScheduler: no active services with a TMDB provider ID found.');
                return;
            }

            for (Streaming_Service__c service : activeServices) {
                // Each service starts its own Queueable chain beginning at page 1.
                // The chain self-terminates when TMDB returns fewer than 20 results.
                System.enqueueJob(new MovieAvailabilitySync(service.Id, 1));
            }

        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                'MovieAvailabilitySyncScheduler failed | ' + e.getTypeName()
                + ': ' + e.getMessage()
                + '\n' + e.getStackTraceString()
            );
        }
    }
}

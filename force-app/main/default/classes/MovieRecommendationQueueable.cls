/**
 * MovieRecommendationQueueable
 *
 * Asynchronous post-session job that refreshes the user's AI taste profile
 * after a swipe session ends.
 *
 * Why a Queueable?
 *   endSwipeSession() performs DML (update Swipe_Session__c) before returning.
 *   Salesforce prohibits callouts in the same transaction as committed DML.
 *   Enqueueing this job defers the LLM callout to a new transaction where the
 *   callout-after-DML restriction no longer applies.
 *
 * Flow:
 *   1. UserInteractionService.endSwipeSession() enqueues this job with the
 *      current user's Id.
 *   2. execute() calls AiRecommendationService.inferTasteProfile(userId).
 *   3. inferTasteProfile reads interaction history, calls the LLM, and upserts
 *      User_Preference__c with the refreshed taste profile JSON.
 *
 * Governor limits:
 *   - One callout per execution (the LLM call inside inferTasteProfile).
 *   - One SOQL to read interactions + one SOQL/DML for the preference upsert.
 *   - Safe to chain additional Queueables here in the future (e.g., match
 *     detection) as long as total callouts stay within the per-transaction limit.
 */
public class MovieRecommendationQueueable implements Queueable, Database.AllowsCallouts {

    private final Id userId;

    public MovieRecommendationQueueable(Id userId) {
        this.userId = userId;
    }

    public void execute(QueueableContext ctx) {
        try {
            AiRecommendationService.inferTasteProfile(userId);
        } catch (Exception e) {
            // Log and swallow — a failed taste-profile refresh should never
            // surface as a user-visible error. The next session end will retry.
            System.debug(LoggingLevel.ERROR,
                'MovieRecommendationQueueable.execute failed for userId=' + userId +
                ' — ' + e.getMessage() + '\n' + e.getStackTraceString()
            );
        }
    }
}

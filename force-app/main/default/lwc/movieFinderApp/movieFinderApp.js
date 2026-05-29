import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class MovieFinderApp extends LightningElement {
    @track serviceFilter = '';

    handleServiceSelected(evt) {
        this.serviceFilter = evt.detail.serviceId;
    }

    handleInteractionRecorded(evt) {
        evt.stopPropagation();
    }

    /**
     * Fired by swipeSession when a session ends.
     * Shows a summary toast and prompts the For You tab to refresh so the
     * newly queued taste-profile update is picked up when the user navigates there.
     */
    handleSessionEnded(evt) {
        const { swipedRight = 0, swipedLeft = 0 } = evt.detail ?? {};
        const total = swipedRight + swipedLeft;

        this.dispatchEvent(new ShowToastEvent({
            title:   'Session complete! 🎬',
            message: `You rated ${total} movie${total === 1 ? '' : 's'} — `
                   + `${swipedRight} liked, ${swipedLeft} passed. `
                   + 'Your For You tab is updating in the background.',
            variant: 'success',
            mode:    'dismissible'
        }));

        // Tell movieRecommendations to reload on its next render.
        // The Queueable updating the taste profile is async, so the component
        // will either show fresh data or fall back gracefully — either is fine.
        const recComponent = this.template.querySelector('c-movie-recommendations');
        if (recComponent) {
            recComponent.refresh();
        }
    }
}

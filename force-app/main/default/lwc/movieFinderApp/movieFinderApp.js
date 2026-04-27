import { LightningElement, track } from 'lwc';

export default class MovieFinderApp extends LightningElement {
    @track serviceFilter = '';

    handleServiceSelected(evt) {
        this.serviceFilter = evt.detail.serviceId;
    }

    handleInteractionRecorded(evt) {
        evt.stopPropagation();
    }

    handleSessionEnded() {
        // Reserved for future shared-session match surfacing (Phase 3).
    }
}
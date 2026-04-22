import { LightningElement, track } from 'lwc';

export default class MovieFinderApp extends LightningElement {
    @track serviceFilter = '';

    handleServiceSelected(evt) {
        this.serviceFilter = evt.detail.serviceId;
    }

    handleInteractionRecorded(evt) {
        // Top-level handler — event is already bubbled up from movieBrowser.
        // Nothing to do here, but stopping propagation to prevent any
        // unintended platform-level bubble behavior.
        evt.stopPropagation();
    }
}
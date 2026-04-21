import { LightningElement, api } from 'lwc';

export default class MovieGrid extends LightningElement {
    @api movies = [];

    get hasMovies() {
        return this.movies && this.movies.length > 0;
    }

    handleInteractionRecorded(evt) {
        // Re-dispatch upward so movieBrowser can update its movies array
        this.dispatchEvent(
            new CustomEvent('interactionrecorded', {
                detail: evt.detail,
                bubbles: true,
                composed: true
            })
        );
    }
}

import { LightningElement, api, track } from 'lwc';

const TMDB_IMAGE_BASE = 'https://image.tmdb.org/t/p/w500';
const OVERVIEW_MAX_LENGTH = 100;

// Minimal grey placeholder as an inline SVG data URI
const PLACEHOLDER_SVG =
    'data:image/svg+xml;charset=UTF-8,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%22200%22%20height%3D%22300%22%3E%3Crect%20width%3D%22200%22%20height%3D%22300%22%20fill%3D%22%232d2d44%22%2F%3E%3C%2Fsvg%3E';

export default class MovieCard extends LightningElement {
    @api movie;
    @track showFallback = false;

    get posterUrl() {
        const posterPath = this.movie?.posterUrl;
        if (posterPath) {
            // posterUrl from the DTO may already be a full URL or just a path —
            // handle both gracefully.
            if (posterPath.startsWith('http')) {
                return posterPath;
            }
            return TMDB_IMAGE_BASE + posterPath;
        }
        return PLACEHOLDER_SVG;
    }

    get overviewSnippet() {
        const overview = this.movie?.overview;
        if (!overview) return '';
        return overview.length > OVERVIEW_MAX_LENGTH
            ? overview.substring(0, OVERVIEW_MAX_LENGTH) + '...'
            : overview;
    }

    handleImageError() {
        this.showFallback = true;
    }

    handleInteractionRecorded(evt) {
        // Bubble the event upward through the shadow boundary
        this.dispatchEvent(
            new CustomEvent('interactionrecorded', {
                detail: evt.detail,
                bubbles: true,
                composed: true
            })
        );
    }
}

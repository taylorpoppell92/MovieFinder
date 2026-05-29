import { LightningElement, track } from 'lwc';
import getPersonalizedRecommendations
    from '@salesforce/apex/MovieFinderController.getPersonalizedRecommendations';

// Governor note: the gate threshold must match the Apex check (< 20).
const GATE_THRESHOLD = 20;

export default class MovieRecommendations extends LightningElement {
    @track movies           = [];
    @track isLoading        = true;
    @track interactionCount = 0;   // populated only when below gate (empty list returned)

    _connected = false;

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    connectedCallback() {
        this._connected = true;
        this._load();
    }

    disconnectedCallback() {
        this._connected = false;
    }

    // -------------------------------------------------------------------------
    // Computed state
    // -------------------------------------------------------------------------

    get hasRecommendations() {
        return !this.isLoading && this.movies.length > 0;
    }

    get showGatePlaceholder() {
        return !this.isLoading && this.movies.length === 0;
    }

    get remaining() {
        return Math.max(0, GATE_THRESHOLD - this.interactionCount);
    }

    get progressPct() {
        return Math.min(100, Math.round((this.interactionCount / GATE_THRESHOLD) * 100));
    }

    get moviesWord() {
        return this.remaining === 1 ? 'movie' : 'movies';
    }

    // -------------------------------------------------------------------------
    // Data loading
    // -------------------------------------------------------------------------

    async _load() {
        this.isLoading = true;
        try {
            const results = await getPersonalizedRecommendations();
            if (!this._connected) return;

            this.movies = results ?? [];

            // If the gate returned empty, fetch interaction count for the
            // progress bar — a lightweight SOQL via a separate wire/imperative
            // call is overkill here; we derive an approximate count from what
            // we know (gate is < 20) and let the user refresh after swiping more.
            if (this.movies.length === 0) {
                // We don't know the exact count from this call; default to 0
                // so the progress bar starts at 0 until a refresh is triggered.
                this.interactionCount = 0;
            }
        } catch (err) {
            console.error('movieRecommendations._load error', err);
            this.movies = [];
        } finally {
            if (this._connected) this.isLoading = false;
        }
    }

    // -------------------------------------------------------------------------
    // Public API — called by movieFinderApp after a swipe session ends
    // -------------------------------------------------------------------------

    /** @api */
    refresh() {
        this._load();
    }

    // -------------------------------------------------------------------------
    // Event handlers
    // -------------------------------------------------------------------------

    handleRefresh() {
        this._load();
    }

    handleInteractionRecorded(evt) {
        const { movieId, interactionType } = evt.detail;
        this.movies = this.movies.map(movie =>
            movie.movieId === movieId
                ? { ...movie, existingInteraction: interactionType }
                : movie
        );
    }
}

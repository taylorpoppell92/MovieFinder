import { LightningElement, track } from 'lwc';
import searchMoviesNL from '@salesforce/apex/MovieFinderController.searchMoviesNL';

export default class MovieSearch extends LightningElement {
    @track query     = '';
    @track movies    = [];
    @track isLoading = false;
    @track searched  = false;  // true once the user has run at least one search

    // -------------------------------------------------------------------------
    // Computed state
    // -------------------------------------------------------------------------

    get isSearchDisabled() {
        return this.isLoading || !this.query.trim();
    }

    get hasResults() {
        return this.searched && !this.isLoading && this.movies.length > 0;
    }

    get showNoResults() {
        return this.searched && !this.isLoading && this.movies.length === 0;
    }

    get showPrompt() {
        return !this.searched && !this.isLoading;
    }

    get resultLabel() {
        const n = this.movies.length;
        return n === 1 ? '1 movie found' : `${n} movies found`;
    }

    // -------------------------------------------------------------------------
    // Event handlers
    // -------------------------------------------------------------------------

    handleQueryChange(evt) {
        this.query = evt.target.value;
    }

    handleKeyUp(evt) {
        if (evt.key === 'Enter' && !this.isSearchDisabled) {
            this.handleSearch();
        }
    }

    async handleSearch() {
        if (!this.query.trim()) return;

        this.isLoading = true;
        this.movies    = [];
        this.searched  = false;

        try {
            const results  = await searchMoviesNL({ query: this.query });
            this.movies    = results ?? [];
            this.searched  = true;
        } catch (err) {
            console.error('movieSearch.handleSearch error', err);
            this.movies   = [];
            this.searched = true;
        } finally {
            this.isLoading = false;
        }
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

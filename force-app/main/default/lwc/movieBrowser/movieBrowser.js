import { LightningElement, api, track } from 'lwc';
import getAvailableMovies from '@salesforce/apex/MovieFinderController.getAvailableMovies';
import getUserSubscriptions from '@salesforce/apex/MovieFinderController.getUserSubscriptions';

const PAGE_SIZE = 20;

export default class MovieBrowser extends LightningElement {
    @track movies = [];
    @track subscriptions = [];
    @track isLoading = false;
    @track hasError = false;
    @track hasMore = true;

    _serviceFilter = '';
    _pageNumber = 1;

    // get/set pattern so we detect when the parent changes serviceFilter
    @api
    get serviceFilter() {
        return this._serviceFilter;
    }
    set serviceFilter(value) {
        this._serviceFilter = value ?? '';
        this.resetAndLoad();
    }

    get isEmpty() {
        return !this.isLoading && this.movies.length === 0;
    }

    connectedCallback() {
        this.loadSubscriptions();
        this.loadMovies();
    }

    async loadSubscriptions() {
        try {
            this.subscriptions = await getUserSubscriptions() ?? [];
        } catch (error) {
            console.error('MovieBrowser: failed to load subscriptions for filter bar', error);
        }
    }

    async loadMovies() {
        if (this.isLoading) return;

        this.isLoading = true;
        this.hasError = false;

        try {
            const results = await getAvailableMovies({
                pageNumber: this._pageNumber,
                pageSize: PAGE_SIZE,
                serviceFilter: this._serviceFilter
            });

            const newMovies = results ?? [];
            this.movies = [...this.movies, ...newMovies];
            this.hasMore = newMovies.length === PAGE_SIZE;
            this._pageNumber += 1;
        } catch (error) {
            this.hasError = true;
            console.error('MovieBrowser: getAvailableMovies failed', error);
        } finally {
            this.isLoading = false;
        }
    }

    resetAndLoad() {
        this.movies = [];
        this._pageNumber = 1;
        this.hasMore = true;
        this.hasError = false;
        this.loadMovies();
    }

    handleFilterChange(evt) {
        this._serviceFilter = evt.detail.serviceFilter ?? '';
        this.resetAndLoad();
    }

    handleLoadMore() {
        if (this.hasMore && !this.isLoading) {
            this.loadMovies();
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
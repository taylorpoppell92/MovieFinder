import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllStreamingServices from '@salesforce/apex/MovieFinderController.getAllStreamingServices';
import getUserSubscriptions from '@salesforce/apex/MovieFinderController.getUserSubscriptions';
import upsertUserSubscription from '@salesforce/apex/MovieFinderController.upsertUserSubscription';

export default class SubscriptionManager extends LightningElement {
    @track mergedServices = [];
    @track isLoading = false;
    @track hasError = false;

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.isLoading = true;
        this.hasError = false;

        try {
            const [allServices, userSubscriptions] = await Promise.all([
                getAllStreamingServices(),
                getUserSubscriptions()
            ]);

            const activeServiceIds = new Set(
                (userSubscriptions || [])
                    .filter(sub => sub.isActive)
                    .map(sub => sub.serviceId)
            );

            this.mergedServices = (allServices || []).map(service => ({
                ...service,
                isSubscribed: activeServiceIds.has(service.serviceId),
                initials: this.getInitials(service.serviceName)
            }));
        } catch (error) {
            this.hasError = true;
            console.error('SubscriptionManager: failed to load data', error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleToggle(evt) {
        const serviceId = evt.target.dataset.serviceId;
        const isActive = evt.target.checked;

        // Optimistically update local state
        this.mergedServices = this.mergedServices.map(service =>
            service.serviceId === serviceId
                ? { ...service, isSubscribed: isActive }
                : service
        );

        try {
            await upsertUserSubscription({ streamingServiceId: serviceId, isActive });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Subscription updated',
                    message: isActive
                        ? 'Service added to your subscriptions.'
                        : 'Service removed from your subscriptions.',
                    variant: 'success'
                })
            );
        } catch (error) {
            // Revert optimistic update on failure
            this.mergedServices = this.mergedServices.map(service =>
                service.serviceId === serviceId
                    ? { ...service, isSubscribed: !isActive }
                    : service
            );
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Update failed',
                    message: 'Could not update subscription. Please try again.',
                    variant: 'error'
                })
            );
            console.error('SubscriptionManager: upsertUserSubscription failed', error);
        }
    }

    handleBrowseService(evt) {
        const serviceId = evt.currentTarget.dataset.serviceId;
        this.dispatchEvent(
            new CustomEvent('serviceselected', {
                detail: { serviceId },
                bubbles: true,
                composed: true
            })
        );
    }

    getInitials(name) {
        if (!name) return '?';
        return name
            .split(' ')
            .slice(0, 2)
            .map(word => word.charAt(0).toUpperCase())
            .join('');
    }
}

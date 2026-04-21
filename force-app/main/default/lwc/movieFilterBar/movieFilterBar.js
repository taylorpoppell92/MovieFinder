import { LightningElement, api, track } from 'lwc';

export default class MovieFilterBar extends LightningElement {
    @api subscriptions = [];
    @track selectedService = '';

    get serviceOptions() {
        const allOption = { label: 'All Services', value: '' };
        const subscriptionOptions = (this.subscriptions || []).map(sub => ({
            label: sub.serviceName,
            value: sub.serviceId
        }));
        return [allOption, ...subscriptionOptions];
    }

    handleServiceChange(evt) {
        this.selectedService = evt.detail.value;
        this.dispatchEvent(
            new CustomEvent('filterchange', {
                detail: { serviceFilter: evt.detail.value }
            })
        );
    }

    handleClear() {
        this.selectedService = '';
        this.dispatchEvent(
            new CustomEvent('filterchange', {
                detail: { serviceFilter: '' }
            })
        );
    }
}

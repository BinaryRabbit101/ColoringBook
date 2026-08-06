<script setup lang="ts">
import { Form, Head } from '@inertiajs/vue3';
import DeviceController from '@/actions/App/Http/Controllers/Settings/DeviceController';
import Heading from '@/components/Heading.vue';
import { Button } from '@/components/ui/button';
import { edit } from '@/routes/devices';

type Device = {
    ulid: string;
    device_uid: string;
    device_name: string | null;
    platform: string | null;
    last_seen_at: string | null;
    is_signed_in: boolean;
};

defineProps<{ devices: Device[] }>();

defineOptions({
    layout: {
        breadcrumbs: [
            {
                title: 'Devices',
                href: edit(),
            },
        ],
    },
});

const formatSeen = (value: string | null): string => {
    if (!value) {
        return 'never';
    }

    return new Date(value).toLocaleString();
};
</script>

<template>
    <Head title="Devices" />

    <h1 class="sr-only">Devices</h1>

    <div class="space-y-6">
        <Heading
            variant="small"
            title="Devices"
            description="Every install that has signed in to this account. Signing one out drops it into offline mode — nothing already coloured is lost."
        />

        <div v-if="devices.length === 0" class="text-sm text-muted-foreground">
            No device has signed in yet.
        </div>

        <ul v-else class="space-y-3">
            <li
                v-for="device in devices"
                :key="device.ulid"
                class="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-4"
            >
                <div class="space-y-0.5">
                    <p class="font-medium">
                        {{ device.device_name ?? 'Unnamed device' }}
                    </p>
                    <p class="text-sm text-muted-foreground">
                        {{ device.platform ?? 'unknown platform' }} · last seen
                        {{ formatSeen(device.last_seen_at) }}
                    </p>
                    <p
                        v-if="!device.is_signed_in"
                        class="text-sm text-muted-foreground"
                    >
                        Signed out
                    </p>
                </div>

                <Form
                    v-if="device.is_signed_in"
                    v-bind="DeviceController.destroy.form(device.ulid)"
                    :options="{ preserveScroll: true }"
                    v-slot="{ processing }"
                >
                    <Button
                        type="submit"
                        variant="destructive"
                        :disabled="processing"
                        :data-test="`sign-out-device-${device.ulid}`"
                    >
                        Sign this device out
                    </Button>
                </Form>
            </li>
        </ul>
    </div>
</template>

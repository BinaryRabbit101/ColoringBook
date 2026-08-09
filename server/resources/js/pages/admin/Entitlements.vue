<script setup lang="ts">
import { Form, Head } from '@inertiajs/vue3';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { AdminEntitlement } from '@/types/admin';

defineProps<{
    packs: { slug: string; title: string; status: string }[];
    entitlements: AdminEntitlement[];
    sources: string[];
}>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Entitlements', href: '/admin/entitlements' }],
    },
});

const selectClass =
    'border-input h-9 w-full rounded-md border bg-transparent px-3 py-1 text-sm shadow-xs outline-none focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px] dark:bg-input/30';
</script>

<template>
    <Head title="Entitlements" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <Heading
            title="Entitlements"
            description="Grant a pack by device id. Granting a revoked claim brings it back."
        />

        <div class="rounded-lg border p-4">
            <Form
                action="/admin/entitlements"
                method="post"
                class="grid gap-3 sm:grid-cols-[2fr_1fr_1fr_auto] sm:items-end"
                v-slot="{ errors, processing }"
            >
                <div class="grid gap-2">
                    <Label for="device_uid">Device id</Label>
                    <Input
                        id="device_uid"
                        name="device_uid"
                        placeholder="01JD…"
                    />
                    <InputError :message="errors.device_uid" />
                </div>

                <div class="grid gap-2">
                    <Label for="pack_slug">Pack</Label>
                    <select
                        id="pack_slug"
                        name="pack_slug"
                        :class="selectClass"
                    >
                        <option
                            v-for="pack in packs"
                            :key="pack.slug"
                            :value="pack.slug"
                        >
                            {{ pack.title }} ({{ pack.status }})
                        </option>
                    </select>
                    <InputError :message="errors.pack_slug" />
                </div>

                <div class="grid gap-2">
                    <Label for="source">Source</Label>
                    <select id="source" name="source" :class="selectClass">
                        <option
                            v-for="source in sources"
                            :key="source"
                            :value="source"
                        >
                            {{ source }}
                        </option>
                    </select>
                    <InputError :message="errors.source" />
                </div>

                <Button type="submit" :disabled="processing">Grant</Button>
            </Form>
        </div>

        <div class="rounded-lg border">
            <div class="border-b p-4">
                <Heading
                    variant="small"
                    title="Recent claims"
                    description="Newest grants first. A revoked row stays until an admin grants it again."
                />
            </div>

            <p
                v-if="entitlements.length === 0"
                class="p-4 text-sm text-muted-foreground"
            >
                Nothing granted yet.
            </p>

            <ul v-else class="divide-y">
                <li
                    v-for="(entitlement, i) in entitlements"
                    :key="i"
                    class="flex flex-wrap items-center justify-between gap-3 p-4 text-sm"
                >
                    <span>{{
                        entitlement.device_name ?? entitlement.device_uid
                    }}</span>
                    <span class="text-muted-foreground">{{
                        entitlement.pack_slug
                    }}</span>
                    <span class="text-muted-foreground">{{
                        entitlement.source
                    }}</span>
                    <span
                        v-if="entitlement.revoked_at"
                        class="rounded-full bg-muted px-2 py-0.5 text-xs text-muted-foreground"
                        >revoked</span
                    >
                    <span
                        v-else
                        class="rounded-full bg-emerald-100 px-2 py-0.5 text-xs text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200"
                        >live</span
                    >
                </li>
            </ul>
        </div>
    </div>
</template>

<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { AdminPack } from '@/types/admin';

defineProps<{ packs: AdminPack[] }>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Packs', href: '/admin/packs' }],
    },
});

const statusClass: Record<string, string> = {
    draft: 'bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-200',
    published:
        'bg-emerald-100 text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200',
    retired: 'bg-muted text-muted-foreground',
};
</script>

<template>
    <Head title="Packs" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <Heading
            title="Packs"
            description="Every pack, drafts included. A pack is published by publishing one of its versions."
        />

        <div v-if="packs.length === 0" class="text-sm text-muted-foreground">
            No packs yet. Reserve a slug below, then upload a built pack zip to
            it.
        </div>

        <ul v-else class="grid gap-3">
            <li
                v-for="pack in packs"
                :key="pack.slug"
                class="rounded-lg border p-4"
            >
                <div class="flex flex-wrap items-center justify-between gap-3">
                    <div>
                        <Link
                            :href="`/admin/packs/${pack.slug}`"
                            class="font-medium underline-offset-4 hover:underline"
                        >
                            {{ pack.title }}
                        </Link>
                        <p class="text-sm text-muted-foreground">
                            {{ pack.slug }} ·
                            {{ pack.version_count }} version(s) ·
                            <template v-if="pack.latest_published_version">
                                latest published v{{
                                    pack.latest_published_version
                                }}
                            </template>
                            <template v-else>nothing published yet</template>
                        </p>
                    </div>

                    <div class="flex items-center gap-2">
                        <span
                            v-if="pack.is_free"
                            class="rounded-full bg-sky-100 px-2 py-0.5 text-xs text-sky-900 dark:bg-sky-900/40 dark:text-sky-200"
                            >free</span
                        >
                        <span
                            class="rounded-full px-2 py-0.5 text-xs"
                            :class="statusClass[pack.status]"
                            >{{ pack.status }}</span
                        >
                    </div>
                </div>
            </li>
        </ul>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="New pack"
                description="The slug is permanent — it is in every URL the game builds for this pack."
            />

            <Form
                action="/admin/packs"
                method="post"
                class="mt-4 grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end"
                v-slot="{ errors, processing }"
            >
                <div class="grid gap-2">
                    <Label for="slug">Slug</Label>
                    <Input id="slug" name="slug" placeholder="forest-friends" />
                    <InputError :message="errors.slug" />
                </div>

                <div class="grid gap-2">
                    <Label for="title">Title</Label>
                    <Input
                        id="title"
                        name="title"
                        placeholder="Forest Friends"
                    />
                    <InputError :message="errors.title" />
                </div>

                <Button type="submit" :disabled="processing">Create</Button>
            </Form>
        </div>
    </div>
</template>

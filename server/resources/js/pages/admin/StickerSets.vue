<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { AuthoredStickerSet } from '@/types/admin';

defineProps<{ stickerSets: AuthoredStickerSet[] }>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Sticker sets', href: '/admin/sticker-sets' }],
    },
});
</script>

<template>
    <Head title="Sticker sets" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <Heading
            title="Sticker sets"
            description="Stickers the game offers past the last crayon box. Each set publishes as its own pack, delivered exactly like a book."
        />

        <div v-if="stickerSets.length === 0" class="text-sm text-muted-foreground">
            No sticker sets yet. Create one below, then add its stickers.
        </div>

        <ul v-else class="grid gap-3">
            <li
                v-for="set in stickerSets"
                :key="set.set_uid"
                class="rounded-lg border p-4"
            >
                <div class="flex flex-wrap items-center justify-between gap-3">
                    <div>
                        <Link
                            :href="`/admin/sticker-sets/${set.set_uid}`"
                            class="font-medium underline-offset-4 hover:underline"
                        >
                            {{ set.title }}
                        </Link>
                        <p class="text-sm text-muted-foreground">
                            {{ set.set_uid }} · {{ set.sticker_count }}
                            sticker(s) ·
                            <template v-if="set.latest_published_version">
                                published v{{ set.latest_published_version }}
                            </template>
                            <template v-else>never published</template>
                        </p>
                    </div>

                    <div class="flex items-center gap-2">
                        <span
                            v-if="set.is_free"
                            class="rounded-full bg-sky-100 px-2 py-0.5 text-xs text-sky-900 dark:bg-sky-900/40 dark:text-sky-200"
                            >free</span
                        >
                        <span
                            v-if="set.unpublishable_sticker_count > 0"
                            class="rounded-full bg-amber-100 px-2 py-0.5 text-xs text-amber-900 dark:bg-amber-900/40 dark:text-amber-200"
                        >
                            {{ set.unpublishable_sticker_count }} sticker(s)
                            need attention
                        </span>
                        <span
                            v-else-if="set.publishable"
                            class="rounded-full bg-emerald-100 px-2 py-0.5 text-xs text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200"
                            >ready to publish</span
                        >
                    </div>
                </div>
            </li>
        </ul>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="New sticker set"
                description="The set id is permanent — every sticker a child has already stuck on a page names it, so it is never reused and never renamed."
            />

            <Form
                action="/admin/sticker-sets"
                method="post"
                class="mt-4 grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end"
                v-slot="{ errors, processing }"
            >
                <div class="grid gap-2">
                    <Label for="set_uid">Set id</Label>
                    <Input
                        id="set_uid"
                        name="set_uid"
                        placeholder="starter-stickers-2026"
                    />
                    <InputError :message="errors.set_uid" />
                </div>

                <div class="grid gap-2">
                    <Label for="title">Title</Label>
                    <Input
                        id="title"
                        name="title"
                        placeholder="Starter Stickers"
                    />
                    <InputError :message="errors.title" />
                </div>

                <div class="grid gap-2">
                    <Label class="flex items-center gap-2 text-sm font-normal">
                        <input
                            type="checkbox"
                            name="is_free"
                            value="1"
                            class="size-4"
                        />
                        Free pack
                    </Label>
                    <Button type="submit" :disabled="processing">Create</Button>
                </div>
            </Form>
        </div>
    </div>
</template>

<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { AuthoredSticker, AuthoredStickerSet } from '@/types/admin';

const props = defineProps<{
    stickerSet: AuthoredStickerSet;
    publishErrors: string[];
}>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Sticker sets', href: '/admin/sticker-sets' }],
    },
});

const base = `/admin/sticker-sets/${props.stickerSet.set_uid}`;

function stickerSummary(sticker: AuthoredSticker): string {
    const size = sticker.image_size
        ? `${sticker.image_size[0]}×${sticker.image_size[1]}`
        : '—';

    return `${size} · ${sticker.file_name}`;
}
</script>

<template>
    <Head :title="stickerSet.title" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <Heading
            :title="stickerSet.title"
            :description="`${stickerSet.set_uid} · pack ${stickerSet.pack_slug} (${stickerSet.pack_status})${stickerSet.is_free ? ' · free' : ''}`"
        />

        <!-- Every reason at once. A set with three broken images should say so
             once, not three times across three attempts. -->
        <div
            v-if="publishErrors.length > 0"
            class="rounded-lg border border-destructive/50 bg-destructive/5 p-4"
        >
            <p class="font-medium text-destructive">
                This sticker set is not ready to publish.
            </p>
            <ul
                class="mt-2 list-disc space-y-1 pl-5 text-sm text-muted-foreground"
            >
                <li v-for="(error, i) in publishErrors" :key="i">
                    {{ error }}
                </li>
            </ul>
        </div>

        <div class="rounded-lg border">
            <div
                class="flex flex-wrap items-center justify-between gap-3 border-b p-4"
            >
                <Heading
                    variant="small"
                    title="Stickers"
                    description="Order is the order they appear on the strip. PNG with transparency — a sticker is a cut-out laid over a drawing."
                />

                <div class="flex items-center gap-2">
                    <Button variant="outline" as-child>
                        <Link :href="`/admin/packs/${stickerSet.pack_slug}`"
                            >Pack</Link
                        >
                    </Button>

                    <Form
                        :action="`${base}/publish`"
                        method="post"
                        v-slot="{ processing }"
                    >
                        <Button
                            type="submit"
                            data-test="publish-sticker-set"
                            :disabled="processing || !stickerSet.publishable"
                        >
                            {{ processing ? 'Publishing…' : 'Publish' }}
                        </Button>
                    </Form>
                </div>
            </div>

            <p
                v-if="
                    !stickerSet.stickers || stickerSet.stickers.length === 0
                "
                class="p-4 text-sm text-muted-foreground"
            >
                No stickers yet.
            </p>

            <ul v-else class="divide-y">
                <li
                    v-for="sticker in stickerSet.stickers"
                    :key="sticker.ulid"
                    class="flex flex-wrap items-center justify-between gap-3 p-4"
                >
                    <div class="flex items-center gap-3">
                        <!-- Checkered behind the art, so a sticker with no
                             transparency is visible as the mistake it is. -->
                        <img
                            :src="sticker.image_url"
                            :alt="sticker.title ?? sticker.sticker_id"
                            class="size-16 rounded border bg-[repeating-conic-gradient(#e5e5e5_0%_25%,#ffffff_0%_50%)] bg-[length:12px_12px] object-contain"
                        />
                        <div>
                            <p class="font-medium">
                                {{ sticker.sticker_index + 1 }}.
                                {{ sticker.title ?? sticker.sticker_id }}
                                <span
                                    class="ml-2 rounded-full bg-muted px-2 py-0.5 text-xs text-muted-foreground"
                                    >{{ sticker.sticker_id }}</span
                                >
                            </p>
                            <p class="text-sm text-muted-foreground">
                                {{ stickerSummary(sticker) }}
                            </p>
                            <p
                                v-if="
                                    !sticker.publishable &&
                                    sticker.blockers.length
                                "
                                class="text-sm text-destructive"
                            >
                                {{ sticker.blockers[0] }}
                            </p>
                            <p
                                v-else-if="sticker.validation_warnings.length"
                                class="text-sm text-amber-700 dark:text-amber-300"
                            >
                                {{ sticker.validation_warnings[0] }}
                            </p>
                        </div>
                    </div>

                    <div class="flex items-center gap-2">
                        <Form
                            v-if="sticker.sticker_index > 0"
                            :action="`${base}/stickers/${sticker.sticker_index}`"
                            method="patch"
                            v-slot="{ processing }"
                        >
                            <input
                                type="hidden"
                                name="sticker_index"
                                :value="sticker.sticker_index - 1"
                            />
                            <Button
                                type="submit"
                                variant="outline"
                                :disabled="processing"
                                >Up</Button
                            >
                        </Form>

                        <Form
                            v-if="
                                stickerSet.stickers &&
                                sticker.sticker_index <
                                    stickerSet.stickers.length - 1
                            "
                            :action="`${base}/stickers/${sticker.sticker_index}`"
                            method="patch"
                            v-slot="{ processing }"
                        >
                            <input
                                type="hidden"
                                name="sticker_index"
                                :value="sticker.sticker_index + 1"
                            />
                            <Button
                                type="submit"
                                variant="outline"
                                :disabled="processing"
                                >Down</Button
                            >
                        </Form>

                        <Form
                            :action="`${base}/stickers/${sticker.sticker_index}`"
                            method="delete"
                            v-slot="{ processing }"
                        >
                            <Button
                                type="submit"
                                variant="outline"
                                :disabled="processing"
                                >Remove</Button
                            >
                        </Form>
                    </div>
                </li>
            </ul>
        </div>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="Add a sticker"
                description="The sticker id is permanent once the set has been published — every placement a child has made names it."
            />

            <Form
                :action="`${base}/stickers`"
                method="post"
                class="mt-4 grid gap-3 sm:grid-cols-[1fr_1fr_1fr_auto] sm:items-end"
                v-slot="{ errors, processing }"
            >
                <div class="grid gap-2">
                    <Label for="image">Sticker image</Label>
                    <Input
                        id="image"
                        name="image"
                        type="file"
                        accept="image/png"
                    />
                    <InputError :message="errors.image" />
                </div>

                <div class="grid gap-2">
                    <Label for="sticker_id">Sticker id</Label>
                    <Input
                        id="sticker_id"
                        name="sticker_id"
                        placeholder="paw-print"
                    />
                    <InputError :message="errors.sticker_id" />
                </div>

                <div class="grid gap-2">
                    <Label for="sticker-title">Name</Label>
                    <Input
                        id="sticker-title"
                        name="title"
                        placeholder="Paw Print"
                    />
                    <InputError :message="errors.title" />
                </div>

                <Button type="submit" :disabled="processing">Add sticker</Button>
            </Form>
        </div>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="Set details"
                description="The set id cannot change. Sort order decides where the set lands in the game's cycle ring, low first."
            />

            <Form
                :action="base"
                method="patch"
                class="mt-4 grid gap-3 sm:grid-cols-[1fr_auto_auto] sm:items-end"
                v-slot="{ errors, processing }"
            >
                <div class="grid gap-2">
                    <Label for="set-title">Title</Label>
                    <Input
                        id="set-title"
                        name="title"
                        :default-value="stickerSet.title"
                    />
                    <InputError :message="errors.title" />
                </div>

                <div class="grid gap-2">
                    <Label for="sort-order">Sort order</Label>
                    <Input
                        id="sort-order"
                        name="sort_order"
                        type="number"
                        min="0"
                        :default-value="stickerSet.sort_order"
                    />
                    <InputError :message="errors.sort_order" />
                </div>

                <Button type="submit" variant="outline" :disabled="processing"
                    >Save</Button
                >
            </Form>

            <Form
                :action="base"
                method="delete"
                class="mt-6 flex items-center justify-between gap-3 rounded-lg border border-destructive/50 p-4"
                v-slot="{ processing }"
            >
                <p class="text-sm text-muted-foreground">
                    <template v-if="stickerSet.latest_published_version">
                        This set has been published, so removing it
                        <strong>retires</strong> its pack — households that own
                        it keep it, and the stickers already stuck on their pages
                        stay put.
                    </template>
                    <template v-else>
                        This set has never been published, so removing it deletes
                        it outright.
                    </template>
                </p>
                <Button
                    type="submit"
                    variant="destructive"
                    :disabled="processing"
                    >Remove set</Button
                >
            </Form>
        </div>
    </div>
</template>

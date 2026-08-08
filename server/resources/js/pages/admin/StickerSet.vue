<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import ConfirmDialog from '@/components/ConfirmDialog.vue';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import SpriteSheetPreview from '@/components/SpriteSheetPreview.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { formatDateTime } from '@/lib/datetime';
import type { AuthoredSticker, AuthoredStickerSet } from '@/types/admin';

/**
 * One sticker set: its stickers as picture rows, replaceable in place (BL-38).
 *
 * The same shape as the book screen, one content kind over, minus the parts a
 * sticker does not have — no mask, no mapping, no second image.
 *
 * What it does have that a page does not is **animation** (BL-38): a sticker's
 * image may be a sprite sheet, described by four numbers that go into the
 * manifest verbatim. The preview beside it plays the sheet at those numbers, so
 * what the artist watches here is what the game will play — a still thumbnail
 * of a sprite sheet is a grid of small drawings and tells them nothing.
 */
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

    if (!sticker.anim) {
        return `${size} · ${sticker.file_name}`;
    }

    return `${size} sheet · ${sticker.anim.hframes}×${sticker.anim.vframes} · ${sticker.anim.frames} frames at ${sticker.anim.fps} fps`;
}
</script>

<template>
    <Head :title="stickerSet.title" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <div class="flex flex-wrap items-start justify-between gap-3">
            <Heading
                :title="stickerSet.title"
                :description="`${stickerSet.set_uid} · pack ${stickerSet.pack_slug} (${stickerSet.pack_status})${stickerSet.is_free ? ' · free' : ''}`"
            />

            <div class="flex flex-wrap items-center gap-2">
                <Button variant="ghost" as-child>
                    <Link :href="`/admin/packs/${stickerSet.pack_slug}`"
                        >Pack</Link
                    >
                </Button>

                <ConfirmDialog
                    :action="base"
                    method="delete"
                    trigger-label="Delete sticker set"
                    trigger-variant="outline"
                    trigger-size="default"
                    data-test="delete-sticker-set"
                    confirm-data-test="confirm-delete-sticker-set"
                    :confirm-label="
                        stickerSet.latest_published_version
                            ? 'Remove and retire'
                            : 'Delete set'
                    "
                    :title="`Delete “${stickerSet.title}”?`"
                    :description="
                        stickerSet.latest_published_version
                            ? 'This set has been published, so removing it retires its pack — households that own it keep it, and the stickers already stuck on their pages stay put. The authoring workspace is deleted.'
                            : 'This set has never been published, so removing it deletes it outright, together with every sticker in it. There is no undo.'
                    "
                />

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
                        {{ processing ? 'Publishing…' : 'Publish sticker set' }}
                    </Button>
                </Form>
            </div>
        </div>

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

        <div class="grid gap-6 lg:grid-cols-[20rem_minmax(0,1fr)]">
            <!-- ------------------------------------------ set details --- -->
            <div class="flex h-fit flex-col gap-4 rounded-lg border p-4">
                <Heading
                    variant="small"
                    title="Set details"
                    description="The set id cannot change. Sort order decides where the set lands in the game's cycle ring, low first."
                />

                <Form
                    :action="base"
                    method="patch"
                    class="grid gap-3"
                    v-slot="{ errors, processing }"
                >
                    <div class="grid gap-2">
                        <Label for="set-title">Name</Label>
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

                    <Button
                        type="submit"
                        size="sm"
                        variant="outline"
                        :disabled="processing"
                        >Save</Button
                    >
                </Form>

                <p class="border-t pt-4 text-xs text-muted-foreground">
                    <template v-if="stickerSet.last_published_at">
                        Last published v{{
                            stickerSet.latest_published_version
                        }}
                        on
                        {{ formatDateTime(stickerSet.last_published_at) }}.
                        <template v-if="stickerSet.modified_since_publish">
                            Edited since.
                        </template>
                    </template>
                    <template v-else>Never published.</template>
                </p>
            </div>

            <!-- ---------------------------------------------- stickers --- -->
            <div class="rounded-lg border">
                <div class="border-b p-4">
                    <Heading
                        variant="small"
                        title="Stickers"
                        description="Order is the order they appear on the strip. PNG with transparency — a sticker is a cut-out laid over a drawing."
                    />
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
                        class="flex flex-wrap items-start gap-4 p-4"
                    >
                        <div class="grid w-32 gap-2">
                            <!-- An animated sticker previews as it plays; a
                                 still sheet of frames would say nothing. -->
                            <SpriteSheetPreview
                                v-if="sticker.anim"
                                :src="sticker.image_url"
                                :anim="sticker.anim"
                                :size="128"
                                :data-test="`sticker-${sticker.sticker_index}-anim`"
                            />
                            <!-- Checkered behind the art, so a sticker with no
                                 transparency is visible as the mistake it is. -->
                            <img
                                v-else
                                :src="sticker.image_url"
                                :alt="sticker.title ?? sticker.sticker_id"
                                class="size-32 rounded border bg-[repeating-conic-gradient(#e5e5e5_0%_25%,#ffffff_0%_50%)] bg-[length:12px_12px] object-contain"
                            />

                            <Form
                                :action="`${base}/stickers/${sticker.sticker_index}`"
                                method="patch"
                                class="grid gap-1"
                                v-slot="{ processing }"
                            >
                                <Input
                                    name="image"
                                    type="file"
                                    accept="image/png"
                                    class="h-8 text-xs"
                                    :aria-label="`Replace the image of ${sticker.sticker_id}`"
                                />
                                <Button
                                    type="submit"
                                    size="sm"
                                    variant="outline"
                                    :disabled="processing"
                                    >Replace image</Button
                                >
                            </Form>
                        </div>

                        <div class="min-w-48 flex-1">
                            <p class="font-medium">
                                {{ sticker.sticker_index + 1 }}.
                                {{ sticker.title ?? sticker.sticker_id }}
                                <span
                                    class="ml-2 rounded-full bg-muted px-2 py-0.5 text-xs text-muted-foreground"
                                    >{{ sticker.sticker_id }}</span
                                >
                                <span
                                    v-if="sticker.anim"
                                    class="ml-1 rounded-full bg-sky-100 px-2 py-0.5 text-xs text-sky-900 dark:bg-sky-900/40 dark:text-sky-200"
                                    >animated</span
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
                                class="mt-1 text-sm text-destructive"
                            >
                                {{ sticker.blockers[0] }}
                            </p>
                            <p
                                v-else-if="sticker.validation_warnings.length"
                                class="mt-1 text-sm text-amber-700 dark:text-amber-300"
                            >
                                {{ sticker.validation_warnings[0] }}
                            </p>

                            <!-- The animation, editable in place: an empty
                                 block turns a sprite sheet back into a still
                                 sticker, which is why every field is submitted
                                 together. -->
                            <Form
                                :action="`${base}/stickers/${sticker.sticker_index}`"
                                method="patch"
                                class="mt-3 grid gap-2 sm:grid-cols-[repeat(4,minmax(0,1fr))_auto] sm:items-end"
                                v-slot="{ errors, processing }"
                            >
                                <div class="grid gap-1">
                                    <Label
                                        :for="`anim-h-${sticker.sticker_index}`"
                                        class="text-xs"
                                        >Columns</Label
                                    >
                                    <Input
                                        :id="`anim-h-${sticker.sticker_index}`"
                                        name="anim[hframes]"
                                        type="number"
                                        min="1"
                                        class="h-8"
                                        :default-value="
                                            sticker.anim?.hframes ?? ''
                                        "
                                    />
                                </div>
                                <div class="grid gap-1">
                                    <Label
                                        :for="`anim-v-${sticker.sticker_index}`"
                                        class="text-xs"
                                        >Rows</Label
                                    >
                                    <Input
                                        :id="`anim-v-${sticker.sticker_index}`"
                                        name="anim[vframes]"
                                        type="number"
                                        min="1"
                                        class="h-8"
                                        :default-value="
                                            sticker.anim?.vframes ?? ''
                                        "
                                    />
                                </div>
                                <div class="grid gap-1">
                                    <Label
                                        :for="`anim-f-${sticker.sticker_index}`"
                                        class="text-xs"
                                        >Frames</Label
                                    >
                                    <Input
                                        :id="`anim-f-${sticker.sticker_index}`"
                                        name="anim[frames]"
                                        type="number"
                                        min="1"
                                        class="h-8"
                                        :default-value="
                                            sticker.anim?.frames ?? ''
                                        "
                                    />
                                </div>
                                <div class="grid gap-1">
                                    <Label
                                        :for="`anim-fps-${sticker.sticker_index}`"
                                        class="text-xs"
                                        >FPS</Label
                                    >
                                    <Input
                                        :id="`anim-fps-${sticker.sticker_index}`"
                                        name="anim[fps]"
                                        type="number"
                                        min="1"
                                        max="30"
                                        step="0.5"
                                        class="h-8"
                                        :default-value="sticker.anim?.fps ?? ''"
                                    />
                                </div>
                                <Button
                                    type="submit"
                                    size="sm"
                                    variant="outline"
                                    :disabled="processing"
                                    >Save animation</Button
                                >

                                <div class="sm:col-span-5">
                                    <InputError
                                        :message="
                                            errors['anim.frames'] ??
                                            errors['anim.hframes'] ??
                                            errors['anim.vframes'] ??
                                            errors['anim.fps']
                                        "
                                    />
                                    <p class="text-xs text-muted-foreground">
                                        Leave all four blank for a still
                                        sticker. Frames are read left to right,
                                        top to bottom, and cannot outnumber the
                                        cells.
                                    </p>
                                </div>
                            </Form>
                        </div>

                        <div class="flex flex-col items-end gap-2">
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
                                        size="sm"
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
                                        size="sm"
                                        variant="outline"
                                        :disabled="processing"
                                        >Down</Button
                                    >
                                </Form>
                            </div>

                            <ConfirmDialog
                                :action="`${base}/stickers/${sticker.sticker_index}`"
                                method="delete"
                                trigger-label="Delete sticker"
                                :data-test="`delete-sticker-${sticker.sticker_index}`"
                                confirm-label="Delete sticker"
                                :title="`Delete “${sticker.title ?? sticker.sticker_id}”?`"
                                description="The sticker is removed from this set and the ones after it move up. There is no undo."
                            />
                        </div>
                    </li>
                </ul>

                <div class="border-t p-4">
                    <Heading
                        variant="small"
                        title="Add sticker"
                        description="The sticker id is permanent once the set has been published — every placement a child has made names it."
                    />

                    <Form
                        :action="`${base}/stickers`"
                        method="post"
                        class="mt-4 grid gap-3"
                        v-slot="{ errors, processing }"
                    >
                        <div
                            class="grid gap-3 sm:grid-cols-[1fr_1fr_1fr_auto] sm:items-end"
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

                            <Button type="submit" :disabled="processing"
                                >Add sticker</Button
                            >
                        </div>

                        <div
                            class="grid gap-3 rounded-lg border border-dashed p-3 sm:grid-cols-[repeat(4,minmax(0,1fr))]"
                        >
                            <p
                                class="text-xs text-muted-foreground sm:col-span-4"
                            >
                                Animated? Upload the sprite sheet above and fill
                                these in. Leave them blank for a still sticker.
                            </p>

                            <div class="grid gap-1">
                                <Label for="new-anim-h" class="text-xs"
                                    >Columns</Label
                                >
                                <Input
                                    id="new-anim-h"
                                    name="anim[hframes]"
                                    type="number"
                                    min="1"
                                    class="h-8"
                                />
                                <InputError :message="errors['anim.hframes']" />
                            </div>
                            <div class="grid gap-1">
                                <Label for="new-anim-v" class="text-xs"
                                    >Rows</Label
                                >
                                <Input
                                    id="new-anim-v"
                                    name="anim[vframes]"
                                    type="number"
                                    min="1"
                                    class="h-8"
                                />
                                <InputError :message="errors['anim.vframes']" />
                            </div>
                            <div class="grid gap-1">
                                <Label for="new-anim-f" class="text-xs"
                                    >Frames</Label
                                >
                                <Input
                                    id="new-anim-f"
                                    name="anim[frames]"
                                    type="number"
                                    min="1"
                                    class="h-8"
                                />
                                <InputError :message="errors['anim.frames']" />
                            </div>
                            <div class="grid gap-1">
                                <Label for="new-anim-fps" class="text-xs"
                                    >FPS</Label
                                >
                                <Input
                                    id="new-anim-fps"
                                    name="anim[fps]"
                                    type="number"
                                    min="1"
                                    max="30"
                                    step="0.5"
                                    class="h-8"
                                />
                                <InputError :message="errors['anim.fps']" />
                            </div>
                        </div>
                    </Form>
                </div>
            </div>
        </div>
    </div>
</template>

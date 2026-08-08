<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import { ref } from 'vue';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import {
    Dialog,
    DialogClose,
    DialogContent,
    DialogDescription,
    DialogFooter,
    DialogHeader,
    DialogTitle,
    DialogTrigger,
} from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { formatDateTime } from '@/lib/datetime';
import type { AuthoredStickerSet } from '@/types/admin';

/**
 * The sticker sets, in the same four columns the book list uses (BL-38).
 *
 * Deliberately the same screen one content kind over: an operator who has
 * learned one list has learned both, and the two really are the same object —
 * a named pile of art with a publish history.
 */
defineProps<{ stickerSets: AuthoredStickerSet[] }>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Sticker sets', href: '/admin/sticker-sets' }],
    },
});

const creating = ref(false);
</script>

<template>
    <Head title="Sticker sets" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <div class="flex flex-wrap items-start justify-between gap-3">
            <Heading
                title="Sticker sets"
                description="Stickers the game offers past the last crayon box. Each set publishes as its own pack, delivered exactly like a book."
            />

            <Dialog v-model:open="creating">
                <DialogTrigger as-child>
                    <Button data-test="create-sticker-set">
                        Create new sticker set
                    </Button>
                </DialogTrigger>

                <DialogContent>
                    <Form
                        action="/admin/sticker-sets"
                        method="post"
                        class="space-y-6"
                        v-slot="{ errors, processing }"
                    >
                        <DialogHeader class="space-y-3">
                            <DialogTitle>New sticker set</DialogTitle>
                            <DialogDescription>
                                The set id is permanent — every sticker a child
                                has already stuck on a page names it, so it is
                                never reused and never renamed.
                            </DialogDescription>
                        </DialogHeader>

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
                            <Label for="title">Name</Label>
                            <Input
                                id="title"
                                name="title"
                                placeholder="Starter Stickers"
                            />
                            <InputError :message="errors.title" />
                        </div>

                        <Label
                            class="flex items-center gap-2 text-sm font-normal"
                        >
                            <input
                                type="checkbox"
                                name="is_free"
                                value="1"
                                class="size-4"
                            />
                            Free pack
                        </Label>

                        <DialogFooter class="gap-2">
                            <DialogClose as-child>
                                <Button type="button" variant="secondary">
                                    Cancel
                                </Button>
                            </DialogClose>
                            <Button type="submit" :disabled="processing">
                                Create
                            </Button>
                        </DialogFooter>
                    </Form>
                </DialogContent>
            </Dialog>
        </div>

        <div
            v-if="stickerSets.length === 0"
            class="rounded-lg border p-8 text-center"
        >
            <p class="text-sm text-muted-foreground">
                No sticker sets yet. Create one, then add its stickers.
            </p>
        </div>

        <div v-else class="overflow-hidden rounded-lg border">
            <div
                class="hidden grid-cols-[minmax(0,3fr)_6rem_minmax(0,1fr)_minmax(0,1.5fr)] gap-4 border-b bg-muted/40 px-4 py-2 text-xs font-medium tracking-wide text-muted-foreground uppercase sm:grid"
            >
                <span>Name</span>
                <span>Stickers</span>
                <span>Status</span>
                <span>Last published</span>
            </div>

            <ul class="divide-y">
                <li v-for="set in stickerSets" :key="set.set_uid">
                    <Link
                        :href="`/admin/sticker-sets/${set.set_uid}`"
                        class="grid grid-cols-1 gap-1 px-4 py-3 transition-colors hover:bg-muted/50 sm:grid-cols-[minmax(0,3fr)_6rem_minmax(0,1fr)_minmax(0,1.5fr)] sm:items-center sm:gap-4"
                    >
                        <span class="min-w-0">
                            <span class="block truncate font-medium">{{
                                set.title
                            }}</span>
                            <span
                                class="block truncate text-xs text-muted-foreground"
                            >
                                {{ set.set_uid
                                }}<template v-if="set.is_free">
                                    · free</template
                                >
                                <template v-if="set.animated_sticker_count > 0">
                                    · {{ set.animated_sticker_count }} animated
                                </template>
                            </span>
                        </span>

                        <span class="text-sm text-muted-foreground">
                            {{ set.sticker_count }}
                            <span class="sm:hidden">sticker(s)</span>
                        </span>

                        <span class="flex flex-wrap items-center gap-2">
                            <span
                                v-if="set.latest_published_version === null"
                                class="rounded-full bg-muted px-2 py-0.5 text-xs text-muted-foreground"
                                >never published</span
                            >
                            <span
                                v-else-if="set.modified_since_publish"
                                class="rounded-full bg-amber-100 px-2 py-0.5 text-xs text-amber-900 dark:bg-amber-900/40 dark:text-amber-200"
                                >edited since publish</span
                            >
                            <span
                                v-else
                                class="rounded-full bg-emerald-100 px-2 py-0.5 text-xs text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200"
                                >published</span
                            >
                            <span
                                v-if="set.unpublishable_sticker_count > 0"
                                class="rounded-full bg-destructive/15 px-2 py-0.5 text-xs text-destructive"
                            >
                                {{ set.unpublishable_sticker_count }} sticker(s)
                                need attention
                            </span>
                            <span
                                v-else-if="
                                    set.publishable &&
                                    set.latest_published_version === null
                                "
                                class="rounded-full bg-emerald-100 px-2 py-0.5 text-xs text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200"
                                >ready to publish</span
                            >
                        </span>

                        <span class="text-sm text-muted-foreground">
                            <template v-if="set.last_published_at">
                                v{{ set.latest_published_version }} ·
                                {{ formatDateTime(set.last_published_at) }}
                            </template>
                            <template v-else>—</template>
                        </span>
                    </Link>
                </li>
            </ul>
        </div>
    </div>
</template>

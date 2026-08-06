<script setup lang="ts">
import { Head, Link } from '@inertiajs/vue3';
import { ref } from 'vue';
import Heading from '@/components/Heading.vue';
import { Button } from '@/components/ui/button';
import type {
    AdminPack,
    AdminPackVersion,
    AdminPreviewPage,
} from '@/types/admin';

defineProps<{
    pack: AdminPack;
    version: AdminPackVersion;
    pages: AdminPreviewPage[];
}>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Packs', href: '/admin/packs' }],
    },
});

// The reviewer's question is "did this page map to the shapes I drew", so the
// overlay is the default view and there is nothing to click to get to it.
const selected = ref(0);
</script>

<template>
    <Head :title="`${pack.title} v${version.version}`" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
            <Heading
                :title="`${pack.title} — v${version.version} preview`"
                description="Each region of the ID map tinted under the display art. Two shapes that should be one region show as two colours."
            />

            <Button variant="outline" as-child>
                <Link :href="`/admin/packs/${pack.slug}`">Back to pack</Link>
            </Button>
        </div>

        <p v-if="pages.length === 0" class="text-sm text-muted-foreground">
            This version has no pages.
        </p>

        <div v-else class="grid gap-6 lg:grid-cols-[16rem_1fr]">
            <ul class="grid h-fit gap-1 rounded-lg border p-2">
                <li v-for="(page, i) in pages" :key="page.preview_url">
                    <button
                        type="button"
                        class="w-full rounded-md px-3 py-2 text-left text-sm"
                        :class="
                            i === selected
                                ? 'bg-accent font-medium'
                                : 'hover:bg-accent/50'
                        "
                        @click="selected = i"
                    >
                        {{ page.book_title }} — page
                        {{ page.page_index + 1 }}
                        <span class="block text-xs text-muted-foreground">
                            {{ page.region_count ?? '?' }} region(s)
                            <template v-if="page.image_size">
                                · {{ page.image_size[0] }}×{{
                                    page.image_size[1]
                                }}
                            </template>
                        </span>
                    </button>
                </li>
            </ul>

            <div class="rounded-lg border p-4">
                <img
                    :src="pages[selected].preview_url"
                    :alt="`Region overlay for ${pages[selected].book_uid} page ${pages[selected].page_index}`"
                    class="mx-auto max-w-full rounded-md"
                />
            </div>
        </div>
    </div>
</template>

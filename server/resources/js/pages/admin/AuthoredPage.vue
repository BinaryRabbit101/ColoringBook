<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { AuthoredBook, AuthoredPage } from '@/types/admin';

const props = defineProps<{
    book: AuthoredBook;
    page: AuthoredPage;
}>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Books', href: '/admin/books' }],
    },
});

const base = `/admin/books/${props.book.book_uid}`;
const url = `${base}/pages/${props.page.page_index}`;

const tuningKnobs: { name: string; label: string; step: string }[] = [
    { name: 'line_alpha_min', label: 'Line alpha min', step: '0.01' },
    { name: 'line_luminance_max', label: 'Line luminance max', step: '0.01' },
    { name: 'dilate', label: 'Dilate (px)', step: '1' },
    { name: 'min_area', label: 'Min region area (px)', step: '1' },
    { name: 'rdp', label: 'Polygon tolerance (px)', step: '0.1' },
    { name: 'giant_fraction', label: 'Giant-region limit', step: '0.01' },
];
</script>

<template>
    <Head :title="page.title ?? `Page ${page.page_index + 1}`" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <Heading
            :title="`${book.title} — page ${page.page_index + 1}`"
            :description="`${page.file_stem} · ${page.mapping_status}`"
        />

        <Button variant="outline" class="w-fit" as-child>
            <Link :href="base">Back to the book</Link>
        </Button>

        <!-- The failure report, in the operator's language. A giant region
             means a line in the drawing has a gap: say so, do not hide it. -->
        <div
            v-if="page.mapping_status === 'failed'"
            class="rounded-lg border border-destructive/50 bg-destructive/5 p-4"
        >
            <p class="font-medium text-destructive">The mapping run failed.</p>
            <p class="mt-1 text-sm text-muted-foreground">
                {{ page.mapping_error }}
            </p>
        </div>

        <div
            v-else-if="page.validation_errors.length > 0"
            class="rounded-lg border border-destructive/50 bg-destructive/5 p-4"
        >
            <p class="font-medium text-destructive">
                This page mapped, but it cannot be published yet.
            </p>
            <ul
                class="mt-2 list-disc space-y-1 pl-5 text-sm text-muted-foreground"
            >
                <li v-for="(error, i) in page.validation_errors" :key="i">
                    {{ error }}
                </li>
            </ul>
        </div>

        <div
            v-if="page.validation_warnings.length > 0"
            class="rounded-lg border border-amber-500/50 bg-amber-500/5 p-4"
        >
            <p class="font-medium">Worth a look</p>
            <ul
                class="mt-2 list-disc space-y-1 pl-5 text-sm text-muted-foreground"
            >
                <li v-for="(warning, i) in page.validation_warnings" :key="i">
                    {{ warning }}
                </li>
            </ul>
        </div>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="Region overlay"
                description="Every region of the ID map tinted a different colour under the art — the same debug overlay the game has. Two shapes you think are one will show as two colours."
            />

            <img
                v-if="page.preview_url"
                :src="page.preview_url"
                alt="Region overlay preview"
                class="mt-4 max-w-full rounded border"
            />
            <p v-else class="mt-4 text-sm text-muted-foreground">
                Nothing to show until this page has mapped.
            </p>

            <dl
                class="mt-4 grid gap-1 text-sm text-muted-foreground sm:grid-cols-2"
            >
                <div>
                    Image size:
                    {{
                        page.image_size
                            ? `${page.image_size[0]}×${page.image_size[1]}`
                            : '—'
                    }}
                </div>
                <div>Regions: {{ page.region_count ?? '—' }}</div>
                <div>Masking image: {{ page.has_mask ? 'yes' : 'no' }}</div>
                <div>Mapped: {{ page.mapped_at ?? '—' }}</div>
            </dl>
        </div>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="Artwork"
                description="Replacing either image re-runs the mapping and clears the old verdict — a stale ID map beside fresh art is the failure the checks exist to catch."
            />

            <Form
                :action="url"
                method="patch"
                class="mt-4 grid gap-3 sm:grid-cols-[1fr_1fr_1fr_auto] sm:items-end"
                v-slot="{ errors, processing }"
            >
                <div class="grid gap-2">
                    <Label for="title">Title</Label>
                    <Input
                        id="title"
                        name="title"
                        :default-value="page.title ?? ''"
                    />
                    <InputError :message="errors.title" />
                </div>

                <div class="grid gap-2">
                    <Label for="display">Replace detail image</Label>
                    <Input
                        id="display"
                        name="display"
                        type="file"
                        accept="image/png"
                    />
                    <InputError :message="errors.display" />
                </div>

                <div class="grid gap-2">
                    <Label for="mask">Replace masking image</Label>
                    <Input
                        id="mask"
                        name="mask"
                        type="file"
                        accept="image/png"
                    />
                    <InputError :message="errors.mask" />
                </div>

                <Button type="submit" :disabled="processing">Save</Button>
            </Form>

            <Form
                v-if="page.has_mask"
                :action="url"
                method="patch"
                class="mt-3"
                v-slot="{ processing }"
            >
                <input type="hidden" name="remove_mask" value="1" />
                <Button type="submit" variant="outline" :disabled="processing">
                    Remove the masking image
                </Button>
            </Form>
        </div>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="Mapping tuning"
                description="Overrides for this page only. Leave a field empty to use the server default. The names are the pipeline's own, so a page tuned here can be reproduced by hand on the dev box."
            />

            <Form
                :action="url"
                method="patch"
                class="mt-4 grid gap-3 sm:grid-cols-3"
                v-slot="{ errors, processing }"
            >
                <div
                    v-for="knob in tuningKnobs"
                    :key="knob.name"
                    class="grid gap-2"
                >
                    <Label :for="knob.name">{{ knob.label }}</Label>
                    <Input
                        :id="knob.name"
                        :name="`tuning[${knob.name}]`"
                        type="number"
                        :step="knob.step"
                        :placeholder="String(page.effective_tuning[knob.name])"
                        :default-value="page.tuning?.[knob.name] ?? ''"
                    />
                    <InputError :message="errors[`tuning.${knob.name}`]" />
                </div>

                <div class="sm:col-span-3">
                    <Button type="submit" :disabled="processing">
                        Save and re-map
                    </Button>
                </div>
            </Form>
        </div>

        <details v-if="page.mapping_log" class="rounded-lg border p-4">
            <summary class="cursor-pointer text-sm font-medium">
                Pipeline output
            </summary>
            <pre class="mt-3 overflow-x-auto text-xs text-muted-foreground">{{
                page.mapping_log
            }}</pre>
        </details>
    </div>
</template>

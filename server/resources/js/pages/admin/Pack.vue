<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { AdminPack, AdminPackVersion } from '@/types/admin';

const props = defineProps<{
    pack: AdminPack;
    versions: AdminPackVersion[];
    validationErrors: string[];
    validationWarnings: string[];
}>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Packs', href: '/admin/packs' }],
    },
});

function kb(bytes: number): string {
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

const uploadUrl = `/admin/packs/${props.pack.slug}/versions`;
</script>

<template>
    <Head :title="pack.title" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <Heading
            :title="pack.title"
            :description="`${pack.slug} · ${pack.status}${pack.is_free ? ' · free' : ''}`"
        />

        <!-- The whole list at once: a build is fixed by reading every problem,
             not by round-tripping one at a time. -->
        <div
            v-if="validationErrors.length > 0"
            class="rounded-lg border border-destructive/50 bg-destructive/5 p-4"
        >
            <p class="font-medium text-destructive">
                That pack did not validate — nothing was created.
            </p>
            <ul
                class="mt-2 list-disc space-y-1 pl-5 text-sm text-muted-foreground"
            >
                <li v-for="(error, i) in validationErrors" :key="i">
                    {{ error }}
                </li>
            </ul>
        </div>

        <div
            v-if="validationWarnings.length > 0"
            class="rounded-lg border border-amber-500/50 bg-amber-500/5 p-4"
        >
            <p class="font-medium">Worth a look before publishing</p>
            <ul
                class="mt-2 list-disc space-y-1 pl-5 text-sm text-muted-foreground"
            >
                <li v-for="(warning, i) in validationWarnings" :key="i">
                    {{ warning }}
                </li>
            </ul>
        </div>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="Upload a version"
                description="A built pack zip — manifest.json plus the files it lists. It is validated and filed as a draft."
            />

            <Form
                :action="uploadUrl"
                method="post"
                class="mt-4 grid gap-3 sm:grid-cols-[1fr_auto] sm:items-end"
                v-slot="{ errors, processing }"
            >
                <div class="grid gap-2">
                    <Label for="archive">pack.zip</Label>
                    <Input
                        id="archive"
                        name="archive"
                        type="file"
                        accept=".zip,application/zip"
                    />
                    <InputError :message="errors.archive" />
                </div>

                <Button type="submit" :disabled="processing">
                    {{ processing ? 'Validating…' : 'Upload draft' }}
                </Button>
            </Form>
        </div>

        <div class="rounded-lg border">
            <div class="border-b p-4">
                <Heading
                    variant="small"
                    title="Versions"
                    description="Published versions are immutable — a fix is always a new version."
                />
            </div>

            <p
                v-if="versions.length === 0"
                class="p-4 text-sm text-muted-foreground"
            >
                No versions yet.
            </p>

            <ul v-else class="divide-y">
                <li
                    v-for="version in versions"
                    :key="version.version"
                    class="flex flex-wrap items-center justify-between gap-3 p-4"
                >
                    <div>
                        <p class="font-medium">
                            v{{ version.version }}
                            <span
                                class="ml-2 rounded-full px-2 py-0.5 text-xs"
                                :class="
                                    version.status === 'published'
                                        ? 'bg-emerald-100 text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200'
                                        : 'bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-200'
                                "
                                >{{ version.status }}</span
                            >
                        </p>
                        <p class="text-sm text-muted-foreground">
                            {{ version.book_count }} book(s) ·
                            {{ version.page_count }} page(s) ·
                            {{ kb(version.bytes) }} · needs client
                            {{ version.min_client_version ?? '—' }}
                        </p>
                    </div>

                    <div class="flex items-center gap-2">
                        <Button variant="outline" as-child>
                            <Link
                                :href="`/admin/packs/${pack.slug}/versions/${version.version}/preview`"
                                >Preview</Link
                            >
                        </Button>

                        <Form
                            v-if="version.status === 'draft'"
                            :action="`/admin/packs/${pack.slug}/versions/${version.version}/publish`"
                            method="post"
                            v-slot="{ processing }"
                        >
                            <Button type="submit" :disabled="processing"
                                >Publish</Button
                            >
                        </Form>
                    </div>
                </li>
            </ul>
        </div>
    </div>
</template>

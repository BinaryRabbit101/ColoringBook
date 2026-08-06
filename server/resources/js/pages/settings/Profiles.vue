<script setup lang="ts">
import { Form, Head } from '@inertiajs/vue3';
import { ref } from 'vue';
import ChildProfileController from '@/actions/App/Http/Controllers/Settings/ChildProfileController';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { edit } from '@/routes/child-profiles';

type ChildProfile = {
    ulid: string;
    nickname: string;
    avatar_index: number;
    default_mode: string;
};

type Props = {
    profiles: ChildProfile[];
    avatarCount: number;
    nicknameMax: number;
    modes: string[];
};

const props = defineProps<Props>();

defineOptions({
    layout: {
        breadcrumbs: [
            {
                title: 'Children',
                href: edit(),
            },
        ],
    },
});

// Which profile is mid-"are you sure?". Removing a child takes their
// colouring with it, so it never happens on a single click.
const confirming = ref<string | null>(null);

const avatarOptions = Array.from({ length: props.avatarCount }, (_, i) => i);

const selectClass =
    'border-input h-9 w-full rounded-md border bg-transparent px-3 py-1 text-sm shadow-xs outline-none focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px] dark:bg-input/30';
</script>

<template>
    <Head title="Children" />

    <h1 class="sr-only">Children</h1>

    <div class="space-y-6">
        <Heading
            variant="small"
            title="Children"
            description="A nickname and an avatar — that is everything we store about a child"
        />

        <div v-if="profiles.length === 0" class="text-sm text-muted-foreground">
            No profiles yet. Add one below and it will show up on the shelf next
            time the game signs in.
        </div>

        <ul v-else class="space-y-4">
            <li
                v-for="profile in profiles"
                :key="profile.ulid"
                class="rounded-lg border p-4"
            >
                <Form
                    v-bind="ChildProfileController.update.form(profile.ulid)"
                    :options="{ preserveScroll: true }"
                    class="grid gap-3 sm:grid-cols-[2fr_1fr_1fr_auto] sm:items-end"
                    v-slot="{ errors, processing }"
                >
                    <div class="grid gap-2">
                        <Label :for="`nickname-${profile.ulid}`"
                            >Nickname</Label
                        >
                        <Input
                            :id="`nickname-${profile.ulid}`"
                            name="nickname"
                            :default-value="profile.nickname"
                            :maxlength="nicknameMax"
                            required
                        />
                        <InputError :message="errors.nickname" />
                    </div>

                    <div class="grid gap-2">
                        <Label :for="`avatar-${profile.ulid}`">Avatar</Label>
                        <select
                            :id="`avatar-${profile.ulid}`"
                            name="avatar_index"
                            :class="selectClass"
                        >
                            <option
                                v-for="index in avatarOptions"
                                :key="index"
                                :value="index"
                                :selected="index === profile.avatar_index"
                            >
                                {{ index }}
                            </option>
                        </select>
                        <InputError :message="errors.avatar_index" />
                    </div>

                    <div class="grid gap-2">
                        <Label :for="`mode-${profile.ulid}`">Mode</Label>
                        <select
                            :id="`mode-${profile.ulid}`"
                            name="default_mode"
                            :class="selectClass"
                        >
                            <option
                                v-for="mode in modes"
                                :key="mode"
                                :value="mode"
                                :selected="mode === profile.default_mode"
                            >
                                {{ mode }}
                            </option>
                        </select>
                        <InputError :message="errors.default_mode" />
                    </div>

                    <Button
                        type="submit"
                        variant="secondary"
                        :disabled="processing"
                        :data-test="`save-profile-${profile.ulid}`"
                    >
                        Save
                    </Button>
                </Form>

                <div class="mt-3 flex items-center gap-3">
                    <Button
                        v-if="confirming !== profile.ulid"
                        variant="ghost"
                        class="text-red-600 dark:text-red-400"
                        :data-test="`remove-profile-${profile.ulid}`"
                        @click="confirming = profile.ulid"
                    >
                        Remove
                    </Button>

                    <template v-else>
                        <p class="text-sm text-muted-foreground">
                            Remove {{ profile.nickname }} and everything they
                            have coloured?
                        </p>
                        <Form
                            v-bind="
                                ChildProfileController.destroy.form(
                                    profile.ulid,
                                )
                            "
                            :options="{ preserveScroll: true }"
                            v-slot="{ processing }"
                        >
                            <Button
                                type="submit"
                                variant="destructive"
                                :disabled="processing"
                                :data-test="`confirm-remove-profile-${profile.ulid}`"
                            >
                                Remove
                            </Button>
                        </Form>
                        <Button variant="ghost" @click="confirming = null">
                            Cancel
                        </Button>
                    </template>
                </div>
            </li>
        </ul>

        <Heading variant="small" title="Add a child" />

        <Form
            v-bind="ChildProfileController.store.form()"
            reset-on-success
            :options="{ preserveScroll: true }"
            class="grid gap-3 sm:grid-cols-[2fr_1fr_1fr_auto] sm:items-end"
            v-slot="{ errors, processing }"
        >
            <div class="grid gap-2">
                <Label for="new-nickname">Nickname</Label>
                <Input
                    id="new-nickname"
                    name="nickname"
                    :maxlength="nicknameMax"
                    placeholder="Nickname"
                    required
                />
                <InputError :message="errors.nickname" />
            </div>

            <div class="grid gap-2">
                <Label for="new-avatar">Avatar</Label>
                <select
                    id="new-avatar"
                    name="avatar_index"
                    :class="selectClass"
                >
                    <option
                        v-for="index in avatarOptions"
                        :key="index"
                        :value="index"
                    >
                        {{ index }}
                    </option>
                </select>
                <InputError :message="errors.avatar_index" />
            </div>

            <div class="grid gap-2">
                <Label for="new-mode">Mode</Label>
                <select id="new-mode" name="default_mode" :class="selectClass">
                    <option v-for="mode in modes" :key="mode" :value="mode">
                        {{ mode }}
                    </option>
                </select>
                <InputError :message="errors.default_mode" />
            </div>

            <Button
                type="submit"
                :disabled="processing"
                data-test="add-profile-button"
            >
                Add
            </Button>
        </Form>
    </div>
</template>

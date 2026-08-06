<?php

namespace App\Concerns;

use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Validation\Rule;

/**
 * The bounds on the only two things we store about a child, plus the mode the
 * game opens them in. Shared by the API and the dashboard requests; all three
 * limits come from `config('coloringbook.profiles')`.
 */
trait ChildProfileValidationRules
{
    /**
     * @return array<int, ValidationRule|array<mixed>|string>
     */
    protected function nicknameRules(): array
    {
        return [
            'string',
            'min:1',
            'max:'.(int) config('coloringbook.profiles.nickname_max'),
        ];
    }

    /**
     * An index into the shipped avatar set — never a URL, never an upload.
     *
     * @return array<int, ValidationRule|array<mixed>|string>
     */
    protected function avatarIndexRules(): array
    {
        $count = (int) config('coloringbook.profiles.avatar_count');

        return ['integer', 'min:0', 'max:'.max(0, $count - 1)];
    }

    /**
     * @return array<int, ValidationRule|array<mixed>|string>
     */
    protected function defaultModeRules(): array
    {
        /** @var array<int, string> $modes */
        $modes = config('coloringbook.profiles.modes');

        return ['string', Rule::in($modes)];
    }
}

<?php

namespace App\Http\Requests\ChildProfiles;

use App\Concerns\ChildProfileValidationRules;
use App\Models\User;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Validator;

/**
 * Create a child profile — used by both `POST /api/v1/profiles` and the
 * parent dashboard, so the bounds can't drift between them.
 */
class StoreChildProfileRequest extends FormRequest
{
    use ChildProfileValidationRules;

    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'nickname' => ['required', ...$this->nicknameRules()],
            'avatar_index' => ['sometimes', ...$this->avatarIndexRules()],
            'default_mode' => ['sometimes', ...$this->defaultModeRules()],
        ];
    }

    /**
     * A guard rail on the number of children per account — not a product
     * limit, just something a scripted client can't walk past.
     *
     * @return array<int, callable>
     */
    public function after(): array
    {
        return [
            function (Validator $validator): void {
                $user = $this->user();

                if (! $user instanceof User) {
                    return;
                }

                $max = (int) config('coloringbook.profiles.max_per_account');

                if ($user->childProfiles()->count() >= $max) {
                    $validator->errors()->add(
                        'nickname',
                        __('This account already has the maximum of :max profiles.', ['max' => $max]),
                    );
                }
            },
        ];
    }

    protected function prepareForValidation(): void
    {
        if (is_string($this->input('nickname'))) {
            $this->merge(['nickname' => trim((string) $this->input('nickname'))]);
        }
    }
}

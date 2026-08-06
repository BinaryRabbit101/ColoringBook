<?php

namespace App\Http\Requests\ChildProfiles;

use App\Concerns\ChildProfileValidationRules;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Foundation\Http\FormRequest;

/**
 * Partial update of a child profile — rename, re-avatar, switch mode. Fields
 * left out are left alone.
 */
class UpdateChildProfileRequest extends FormRequest
{
    use ChildProfileValidationRules;

    /**
     * @return array<string, ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'nickname' => ['sometimes', 'required', ...$this->nicknameRules()],
            'avatar_index' => ['sometimes', 'required', ...$this->avatarIndexRules()],
            'default_mode' => ['sometimes', 'required', ...$this->defaultModeRules()],
        ];
    }

    protected function prepareForValidation(): void
    {
        if (is_string($this->input('nickname'))) {
            $this->merge(['nickname' => trim((string) $this->input('nickname'))]);
        }
    }
}

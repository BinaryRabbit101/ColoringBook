<?php

namespace App\Providers;

use App\Services\Mapping\GodotMappingRunner;
use App\Services\Mapping\MappingRunner;
use Carbon\CarbonImmutable;
use Illuminate\Http\Resources\Json\JsonResource;
use Illuminate\Support\Facades\Date;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\ServiceProvider;
use Illuminate\Validation\Rules\Password;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        // BL-24: the only seam between this application and the mapping
        // pipeline. Real runs shell out to headless Godot; the test suite
        // swaps in a fake so the gate stays green on a box with no engine.
        // There is no PHP implementation of the pipeline and never will be
        // (DLC_SERVER.md §10.1).
        $this->app->bind(MappingRunner::class, GodotMappingRunner::class);
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        $this->configureDefaults();
    }

    /**
     * Configure default behaviors for production-ready applications.
     */
    protected function configureDefaults(): void
    {
        Date::use(CarbonImmutable::class);

        // API responses are hand-shaped per DLC_SERVER.md §11 — {token, …},
        // {user, profiles, devices} — so resources must not wrap themselves
        // in a "data" key.
        JsonResource::withoutWrapping();

        DB::prohibitDestructiveCommands(
            app()->isProduction(),
        );

        Password::defaults(fn (): ?Password => app()->isProduction()
            ? Password::min(12)
                ->mixedCase()
                ->letters()
                ->numbers()
                ->symbols()
                ->uncompromised()
            : null,
        );
    }
}

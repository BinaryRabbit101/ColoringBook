<?php

/*
 * The root of the private content tree, relative to `storage/app`, as declared
 * by `coloringbook.storage.private_root`. The three private disks below are
 * rooted at `<private_root>/{packs,assets}` — read here rather than
 * through `config()` because a disk's root has to be a literal by the time the
 * filesystem manager resolves it.
 *
 * It exists so a browser-test run can be given its own tree
 * (`.env.dusk.local` sets `private/dusk`) instead of writing pack and asset
 * blobs into the developer's own `storage/app/private/`, where nothing in the
 * dev database would ever account for them again.
 */
$private = 'app/'.trim((string) env('COLORINGBOOK_PRIVATE_ROOT', 'private'), '/');

/*
 * Permissions for the two private disks below.
 *
 * Flysystem's local adapter creates "private" files 0600 and directories 0700 by
 * default, owned by whoever ran the process. On the deployed box that is *two*
 * different users: `php artisan pack:publish` runs as the operator over SSH, while
 * every read is PHP-FPM as `www-data`. 0700 means www-data cannot even traverse
 * `packs/<slug>/`, so an import that looked perfectly successful answers every
 * download with `FILE_NOT_FOUND` — and the only fix was a manual
 * `chmod -R g+rX storage/app/private` after each publish, remembered or not.
 *
 * Group-readable (0750 / 0640) is the smallest change that makes the two users
 * agree. The deployed tree is `gemini:www-data` with the setgid bit set, so every
 * directory Flysystem creates inherits the serving group; the mode is the only
 * half PHP controls, and it is the half that was wrong. www-data can then read
 * the bytes it is asked to serve and still cannot write them. World access stays
 * off — these files are private by design, reachable only through an authorised
 * controller (or the X-Accel-Redirect Nginx follows as root).
 */
$privatePermissions = [
    'file' => ['public' => 0644, 'private' => 0640],
    'dir' => ['public' => 0755, 'private' => 0750],
];

return [

    /*
    |--------------------------------------------------------------------------
    | Default Filesystem Disk
    |--------------------------------------------------------------------------
    |
    | Here you may specify the default filesystem disk that should be used
    | by the framework. The "local" disk, as well as a variety of cloud
    | based disks are available to your application for file storage.
    |
    */

    'default' => env('FILESYSTEM_DISK', 'local'),

    /*
    |--------------------------------------------------------------------------
    | Filesystem Disks
    |--------------------------------------------------------------------------
    |
    | Below you may configure as many filesystem disks as necessary, and you
    | may even configure multiple disks for the same driver. Examples for
    | most supported storage drivers are configured here for reference.
    |
    | Supported drivers: "local", "ftp", "sftp", "s3"
    |
    */

    'disks' => [

        'local' => [
            'driver' => 'local',
            'root' => storage_path('app/private'),
            'serve' => true,
            'throw' => false,
            'report' => false,
        ],

        'public' => [
            'driver' => 'local',
            'root' => storage_path('app/public'),
            'url' => rtrim((string) env('APP_URL', 'http://localhost'), '/').'/storage',
            'visibility' => 'public',
            'throw' => false,
            'report' => false,
        ],

        /*
         * Private content disks — DLC_SERVER.md §5 "Storage layout on disk".
         * Never web-readable: every byte is served through an authorised
         * controller (streamed, or handed to Nginx via X-Accel-Redirect when
         * config('coloringbook.accel_redirect') is on).
         */

        'packs' => [
            'driver' => 'local',
            'root' => storage_path($private.'/packs'),
            'serve' => false,
            'permissions' => $privatePermissions,
            'throw' => true,
            'report' => false,
        ],

        'assets' => [
            'driver' => 'local',
            'root' => storage_path($private.'/assets'),
            'serve' => false,
            'permissions' => $privatePermissions,
            'throw' => true,
            'report' => false,
        ],

        's3' => [
            'driver' => 's3',
            'key' => env('AWS_ACCESS_KEY_ID'),
            'secret' => env('AWS_SECRET_ACCESS_KEY'),
            'region' => env('AWS_DEFAULT_REGION'),
            'bucket' => env('AWS_BUCKET'),
            'url' => env('AWS_URL'),
            'endpoint' => env('AWS_ENDPOINT'),
            'use_path_style_endpoint' => env('AWS_USE_PATH_STYLE_ENDPOINT', false),
            'throw' => false,
            'report' => false,
        ],

    ],

    /*
    |--------------------------------------------------------------------------
    | Symbolic Links
    |--------------------------------------------------------------------------
    |
    | Here you may configure the symbolic links that will be created when the
    | `storage:link` Artisan command is executed. The array keys should be
    | the locations of the links and the values should be their targets.
    |
    */

    'links' => [
        public_path('storage') => storage_path('app/public'),
    ],

];

export type User = {
    id: number;
    // Accounts created from the game never supplied a name — email and
    // password are the whole PII footprint (DLC_SERVER.md §4.1).
    name: string | null;
    email: string;
    avatar?: string;
    email_verified_at: string | null;
    // The whole authorisation model for the publishing tool (DLC_SERVER.md
    // §10.2): one boolean, no roles.
    is_admin?: boolean;
    two_factor_enabled?: boolean;
    created_at: string;
    updated_at: string;
    [key: string]: unknown;
};

export type Auth = {
    user: User;
};

/* @chisel-passkeys */
export type Passkey = {
    id: number;
    name: string;
    authenticator: string | null;
    created_at_diff: string;
    last_used_at_diff: string | null;
};
/* @end-chisel-passkeys */

export type TwoFactorConfigContent = {
    title: string;
    description: string;
    buttonText: string;
};

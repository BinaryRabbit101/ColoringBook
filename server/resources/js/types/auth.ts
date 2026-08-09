export type User = {
    id: number;
    // The operator's own row. `users` holds nobody else — a player is a
    // device, and a device has no name, no email and no password.
    name: string | null;
    email: string;
    avatar?: string;
    email_verified_at: string | null;
    // The whole authorisation model for the publishing tool (DLC_SERVER.md
    // §10.2): one boolean, no roles.
    is_admin?: boolean;
    created_at: string;
    updated_at: string;
    [key: string]: unknown;
};

export type Auth = {
    user: User;
};

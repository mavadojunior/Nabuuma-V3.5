create extension if not exists pgcrypto;

create table if not exists public._nabuuma_deployment_bootstrap (id integer primary key default 1, initialized_at timestamptz not null default now());
insert into public._nabuuma_deployment_bootstrap(id) values (1) on conflict (id) do nothing;

-- The integrated release's canonical base schema is applied by the following migration files.
-- Foundry dbt pipeline - schema name macro
--
-- WHY THIS FILE:
-- By default dbt joins two names: <target schema>_<custom schema>.
-- Our target schema (profiles.yml) is SILVER, and dbt_project.yml sets
-- +schema SILVER / GOLD for the model folders.
--
--   BEFORE (dbt default):  Silver model -> SILVER_SILVER
--                          Gold model   -> SILVER_GOLD
--   AFTER  (this macro):   Silver model -> SILVER
--                          Gold model   -> GOLD
--
-- RULE:
--   1. Model has +schema  -> use that name exactly (SILVER, GOLD, MONITORING).
--   2. Model has no +schema -> use the target schema from profiles.yml.
--
-- dbt finds this macro by its name and uses it instead of its own default.
-- No source table or column names here: it works for any project.

{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}

    {%- if custom_schema_name is none -%}
        {# 2. no +schema: target schema from profiles.yml #}
        {{ default_schema }}
    {%- else -%}
        {# 1. +schema given: use it as-is (spaces removed) #}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}

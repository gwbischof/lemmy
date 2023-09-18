--
-- PostgreSQL database dump
--

-- Dumped from database version 14.9 (Ubuntu 14.9-0ubuntu0.22.04.1)
-- Dumped by pg_dump version 14.9 (Ubuntu 14.9-0ubuntu0.22.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: utils; Type: SCHEMA; Schema: -; Owner: lemmy
--

CREATE SCHEMA utils;


ALTER SCHEMA utils OWNER TO lemmy;

--
-- Name: ltree; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS ltree WITH SCHEMA public;


--
-- Name: EXTENSION ltree; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION ltree IS 'data type for hierarchical tree-like structures';


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: actor_type_enum; Type: TYPE; Schema: public; Owner: lemmy
--

CREATE TYPE public.actor_type_enum AS ENUM (
    'site',
    'community',
    'person'
);


ALTER TYPE public.actor_type_enum OWNER TO lemmy;

--
-- Name: listing_type_enum; Type: TYPE; Schema: public; Owner: lemmy
--

CREATE TYPE public.listing_type_enum AS ENUM (
    'All',
    'Local',
    'Subscribed',
    'ModeratorView'
);


ALTER TYPE public.listing_type_enum OWNER TO lemmy;

--
-- Name: post_listing_mode_enum; Type: TYPE; Schema: public; Owner: lemmy
--

CREATE TYPE public.post_listing_mode_enum AS ENUM (
    'List',
    'Card',
    'SmallCard'
);


ALTER TYPE public.post_listing_mode_enum OWNER TO lemmy;

--
-- Name: registration_mode_enum; Type: TYPE; Schema: public; Owner: lemmy
--

CREATE TYPE public.registration_mode_enum AS ENUM (
    'Closed',
    'RequireApplication',
    'Open'
);


ALTER TYPE public.registration_mode_enum OWNER TO lemmy;

--
-- Name: sort_type_enum; Type: TYPE; Schema: public; Owner: lemmy
--

CREATE TYPE public.sort_type_enum AS ENUM (
    'Active',
    'Hot',
    'New',
    'Old',
    'TopDay',
    'TopWeek',
    'TopMonth',
    'TopYear',
    'TopAll',
    'MostComments',
    'NewComments',
    'TopHour',
    'TopSixHour',
    'TopTwelveHour',
    'TopThreeMonths',
    'TopSixMonths',
    'TopNineMonths',
    'Controversial',
    'Scaled'
);


ALTER TYPE public.sort_type_enum OWNER TO lemmy;

--
-- Name: comment_aggregates_comment(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.comment_aggregates_comment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO comment_aggregates (comment_id, published)
            VALUES (NEW.id, NEW.published);
    ELSIF (TG_OP = 'DELETE') THEN
        DELETE FROM comment_aggregates
        WHERE comment_id = OLD.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.comment_aggregates_comment() OWNER TO lemmy;

--
-- Name: comment_aggregates_score(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.comment_aggregates_score() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        UPDATE
            comment_aggregates ca
        SET
            score = score + NEW.score,
            upvotes = CASE WHEN NEW.score = 1 THEN
                upvotes + 1
            ELSE
                upvotes
            END,
            downvotes = CASE WHEN NEW.score = - 1 THEN
                downvotes + 1
            ELSE
                downvotes
            END,
            controversy_rank = controversy_rank (ca.upvotes + CASE WHEN NEW.score = 1 THEN
                    1
                ELSE
                    0
                END::numeric, ca.downvotes + CASE WHEN NEW.score = - 1 THEN
                    1
                ELSE
                    0
                END::numeric)
        WHERE
            ca.comment_id = NEW.comment_id;
    ELSIF (TG_OP = 'DELETE') THEN
        -- Join to comment because that comment may not exist anymore
        UPDATE
            comment_aggregates ca
        SET
            score = score - OLD.score,
            upvotes = CASE WHEN OLD.score = 1 THEN
                upvotes - 1
            ELSE
                upvotes
            END,
            downvotes = CASE WHEN OLD.score = - 1 THEN
                downvotes - 1
            ELSE
                downvotes
            END,
            controversy_rank = controversy_rank (ca.upvotes + CASE WHEN NEW.score = 1 THEN
                    1
                ELSE
                    0
                END::numeric, ca.downvotes + CASE WHEN NEW.score = - 1 THEN
                    1
                ELSE
                    0
                END::numeric)
        FROM
            comment c
        WHERE
            ca.comment_id = c.id
            AND ca.comment_id = OLD.comment_id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.comment_aggregates_score() OWNER TO lemmy;

--
-- Name: comment_removed_resolve_reports(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.comment_removed_resolve_reports() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE
        comment_report
    SET
        resolved = TRUE,
        resolver_id = NEW.mod_person_id,
        updated = now()
    WHERE
        comment_report.comment_id = NEW.comment_id;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.comment_removed_resolve_reports() OWNER TO lemmy;

--
-- Name: community_aggregates_activity(text); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.community_aggregates_activity(i text) RETURNS TABLE(count_ bigint, community_id_ integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN query
    SELECT
        count(*),
        community_id
    FROM (
        SELECT
            c.creator_id,
            p.community_id
        FROM
            comment c
            INNER JOIN post p ON c.post_id = p.id
            INNER JOIN person pe ON c.creator_id = pe.id
        WHERE
            c.published > ('now'::timestamp - i::interval)
            AND pe.bot_account = FALSE
        UNION
        SELECT
            p.creator_id,
            p.community_id
        FROM
            post p
            INNER JOIN person pe ON p.creator_id = pe.id
        WHERE
            p.published > ('now'::timestamp - i::interval)
            AND pe.bot_account = FALSE) a
GROUP BY
    community_id;
END;
$$;


ALTER FUNCTION public.community_aggregates_activity(i text) OWNER TO lemmy;

--
-- Name: community_aggregates_comment_count(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.community_aggregates_comment_count() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (was_restored_or_created (TG_OP, OLD, NEW)) THEN
        UPDATE
            community_aggregates ca
        SET
            comments = comments + 1
        FROM
            post p
        WHERE
            p.id = NEW.post_id
            AND ca.community_id = p.community_id;
    ELSIF (was_removed_or_deleted (TG_OP, OLD, NEW)) THEN
        UPDATE
            community_aggregates ca
        SET
            comments = comments - 1
        FROM
            post p
        WHERE
            p.id = OLD.post_id
            AND ca.community_id = p.community_id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.community_aggregates_comment_count() OWNER TO lemmy;

--
-- Name: community_aggregates_community(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.community_aggregates_community() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO community_aggregates (community_id, published)
            VALUES (NEW.id, NEW.published);
    ELSIF (TG_OP = 'DELETE') THEN
        DELETE FROM community_aggregates
        WHERE community_id = OLD.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.community_aggregates_community() OWNER TO lemmy;

--
-- Name: community_aggregates_post_count(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.community_aggregates_post_count() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (was_restored_or_created (TG_OP, OLD, NEW)) THEN
        UPDATE
            community_aggregates
        SET
            posts = posts + 1
        WHERE
            community_id = NEW.community_id;
        IF (TG_OP = 'UPDATE') THEN
            -- Post was restored, so restore comment counts as well
            UPDATE
                community_aggregates ca
            SET
                posts = coalesce(cd.posts, 0),
                comments = coalesce(cd.comments, 0)
            FROM (
                SELECT
                    c.id,
                    count(DISTINCT p.id) AS posts,
                    count(DISTINCT ct.id) AS comments
                FROM
                    community c
                LEFT JOIN post p ON c.id = p.community_id
                    AND p.deleted = 'f'
                    AND p.removed = 'f'
            LEFT JOIN comment ct ON p.id = ct.post_id
                AND ct.deleted = 'f'
                AND ct.removed = 'f'
        WHERE
            c.id = NEW.community_id
        GROUP BY
            c.id) cd
        WHERE
            ca.community_id = NEW.community_id;
        END IF;
    ELSIF (was_removed_or_deleted (TG_OP, OLD, NEW)) THEN
        UPDATE
            community_aggregates
        SET
            posts = posts - 1
        WHERE
            community_id = OLD.community_id;
        -- Update the counts if the post got deleted
        UPDATE
            community_aggregates ca
        SET
            posts = coalesce(cd.posts, 0),
            comments = coalesce(cd.comments, 0)
        FROM (
            SELECT
                c.id,
                count(DISTINCT p.id) AS posts,
                count(DISTINCT ct.id) AS comments
            FROM
                community c
            LEFT JOIN post p ON c.id = p.community_id
                AND p.deleted = 'f'
                AND p.removed = 'f'
        LEFT JOIN comment ct ON p.id = ct.post_id
            AND ct.deleted = 'f'
            AND ct.removed = 'f'
    WHERE
        c.id = OLD.community_id
    GROUP BY
        c.id) cd
    WHERE
        ca.community_id = OLD.community_id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.community_aggregates_post_count() OWNER TO lemmy;

--
-- Name: community_aggregates_subscriber_count(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.community_aggregates_subscriber_count() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        UPDATE
            community_aggregates
        SET
            subscribers = subscribers + 1
        WHERE
            community_id = NEW.community_id;
    ELSIF (TG_OP = 'DELETE') THEN
        UPDATE
            community_aggregates
        SET
            subscribers = subscribers - 1
        WHERE
            community_id = OLD.community_id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.community_aggregates_subscriber_count() OWNER TO lemmy;

--
-- Name: controversy_rank(numeric, numeric); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.controversy_rank(upvotes numeric, downvotes numeric) RETURNS double precision
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    IF downvotes <= 0 OR upvotes <= 0 THEN
        RETURN 0;
    ELSE
        RETURN (upvotes + downvotes) * CASE WHEN upvotes > downvotes THEN
            downvotes::float / upvotes::float
        ELSE
            upvotes::float / downvotes::float
        END;
    END IF;
END;
$$;


ALTER FUNCTION public.controversy_rank(upvotes numeric, downvotes numeric) OWNER TO lemmy;

--
-- Name: diesel_manage_updated_at(regclass); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.diesel_manage_updated_at(_tbl regclass) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    EXECUTE format('CREATE TRIGGER set_updated_at BEFORE UPDATE ON %s
                    FOR EACH ROW EXECUTE PROCEDURE diesel_set_updated_at()', _tbl);
END;
$$;


ALTER FUNCTION public.diesel_manage_updated_at(_tbl regclass) OWNER TO lemmy;

--
-- Name: diesel_set_updated_at(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.diesel_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW IS DISTINCT FROM OLD AND NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at) THEN
        NEW.updated_at := CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.diesel_set_updated_at() OWNER TO lemmy;

--
-- Name: drop_ccnew_indexes(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.drop_ccnew_indexes() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    i RECORD;
BEGIN
    FOR i IN (
        SELECT
            relname
        FROM
            pg_class
        WHERE
            relname LIKE '%ccnew%')
        LOOP
            EXECUTE 'DROP INDEX ' || i.relname;
        END LOOP;
    RETURN 1;
END;
$$;


ALTER FUNCTION public.drop_ccnew_indexes() OWNER TO lemmy;

--
-- Name: generate_unique_changeme(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.generate_unique_changeme() RETURNS text
    LANGUAGE sql
    AS $$
    SELECT
        'http://changeme.invalid/' || substr(md5(random()::text), 0, 25);
$$;


ALTER FUNCTION public.generate_unique_changeme() OWNER TO lemmy;

--
-- Name: hot_rank(numeric, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.hot_rank(score numeric, published timestamp without time zone) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    AS $$
DECLARE
    hours_diff numeric := EXTRACT(EPOCH FROM (timezone('utc', now()) - published)) / 3600;
BEGIN
    IF (hours_diff > 0) THEN
        RETURN floor(10000 * log(greatest (1, score + 3)) / power((hours_diff + 2), 1.8))::integer;
    ELSE
        RETURN 0;
    END IF;
END;
$$;


ALTER FUNCTION public.hot_rank(score numeric, published timestamp without time zone) OWNER TO lemmy;

--
-- Name: hot_rank(numeric, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.hot_rank(score numeric, published timestamp with time zone) RETURNS double precision
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    AS $$
DECLARE
    hours_diff numeric := EXTRACT(EPOCH FROM (now() - published)) / 3600;
BEGIN
    -- 24 * 7 = 168, so after a week, it will default to 0.
    IF (hours_diff > 0 AND hours_diff < 168) THEN
        RETURN log(greatest (1, score + 3)) / power((hours_diff + 2), 1.8);
    ELSE
        -- if the post is from the future, set hot score to 0. otherwise you can game the post to
        -- always be on top even with only 1 vote by setting it to the future
        RETURN 0.0;
    END IF;
END;
$$;


ALTER FUNCTION public.hot_rank(score numeric, published timestamp with time zone) OWNER TO lemmy;

--
-- Name: person_aggregates_comment_count(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.person_aggregates_comment_count() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (was_restored_or_created (TG_OP, OLD, NEW)) THEN
        UPDATE
            person_aggregates
        SET
            comment_count = comment_count + 1
        WHERE
            person_id = NEW.creator_id;
    ELSIF (was_removed_or_deleted (TG_OP, OLD, NEW)) THEN
        UPDATE
            person_aggregates
        SET
            comment_count = comment_count - 1
        WHERE
            person_id = OLD.creator_id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.person_aggregates_comment_count() OWNER TO lemmy;

--
-- Name: person_aggregates_comment_score(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.person_aggregates_comment_score() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        -- Need to get the post creator, not the voter
        UPDATE
            person_aggregates ua
        SET
            comment_score = comment_score + NEW.score
        FROM
            comment c
        WHERE
            ua.person_id = c.creator_id
            AND c.id = NEW.comment_id;
    ELSIF (TG_OP = 'DELETE') THEN
        UPDATE
            person_aggregates ua
        SET
            comment_score = comment_score - OLD.score
        FROM
            comment c
        WHERE
            ua.person_id = c.creator_id
            AND c.id = OLD.comment_id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.person_aggregates_comment_score() OWNER TO lemmy;

--
-- Name: person_aggregates_person(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.person_aggregates_person() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO person_aggregates (person_id)
            VALUES (NEW.id);
    ELSIF (TG_OP = 'DELETE') THEN
        DELETE FROM person_aggregates
        WHERE person_id = OLD.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.person_aggregates_person() OWNER TO lemmy;

--
-- Name: person_aggregates_post_count(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.person_aggregates_post_count() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (was_restored_or_created (TG_OP, OLD, NEW)) THEN
        UPDATE
            person_aggregates
        SET
            post_count = post_count + 1
        WHERE
            person_id = NEW.creator_id;
    ELSIF (was_removed_or_deleted (TG_OP, OLD, NEW)) THEN
        UPDATE
            person_aggregates
        SET
            post_count = post_count - 1
        WHERE
            person_id = OLD.creator_id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.person_aggregates_post_count() OWNER TO lemmy;

--
-- Name: person_aggregates_post_score(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.person_aggregates_post_score() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        -- Need to get the post creator, not the voter
        UPDATE
            person_aggregates ua
        SET
            post_score = post_score + NEW.score
        FROM
            post p
        WHERE
            ua.person_id = p.creator_id
            AND p.id = NEW.post_id;
    ELSIF (TG_OP = 'DELETE') THEN
        UPDATE
            person_aggregates ua
        SET
            post_score = post_score - OLD.score
        FROM
            post p
        WHERE
            ua.person_id = p.creator_id
            AND p.id = OLD.post_id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.person_aggregates_post_score() OWNER TO lemmy;

--
-- Name: post_aggregates_comment_count(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.post_aggregates_comment_count() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Check for post existence - it may not exist anymore
    IF TG_OP = 'INSERT' OR EXISTS (
        SELECT
            1
        FROM
            post p
        WHERE
            p.id = OLD.post_id) THEN
        IF (was_restored_or_created (TG_OP, OLD, NEW)) THEN
            UPDATE
                post_aggregates pa
            SET
                comments = comments + 1
            WHERE
                pa.post_id = NEW.post_id;
        ELSIF (was_removed_or_deleted (TG_OP, OLD, NEW)) THEN
            UPDATE
                post_aggregates pa
            SET
                comments = comments - 1
            WHERE
                pa.post_id = OLD.post_id;
        END IF;
    END IF;
    IF TG_OP = 'INSERT' THEN
        UPDATE
            post_aggregates pa
        SET
            newest_comment_time = NEW.published
        WHERE
            pa.post_id = NEW.post_id;
        -- A 2 day necro-bump limit
        UPDATE
            post_aggregates pa
        SET
            newest_comment_time_necro = NEW.published
        FROM
            post p
        WHERE
            pa.post_id = p.id
            AND pa.post_id = NEW.post_id
            -- Fix issue with being able to necro-bump your own post
            AND NEW.creator_id != p.creator_id
            AND pa.published > ('now'::timestamp - '2 days'::interval);
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.post_aggregates_comment_count() OWNER TO lemmy;

--
-- Name: post_aggregates_featured_community(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.post_aggregates_featured_community() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE
        post_aggregates pa
    SET
        featured_community = NEW.featured_community
    WHERE
        pa.post_id = NEW.id;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.post_aggregates_featured_community() OWNER TO lemmy;

--
-- Name: post_aggregates_featured_local(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.post_aggregates_featured_local() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE
        post_aggregates pa
    SET
        featured_local = NEW.featured_local
    WHERE
        pa.post_id = NEW.id;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.post_aggregates_featured_local() OWNER TO lemmy;

--
-- Name: post_aggregates_post(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.post_aggregates_post() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO post_aggregates (post_id, published, newest_comment_time, newest_comment_time_necro, community_id, creator_id)
            VALUES (NEW.id, NEW.published, NEW.published, NEW.published, NEW.community_id, NEW.creator_id);
    ELSIF (TG_OP = 'DELETE') THEN
        DELETE FROM post_aggregates
        WHERE post_id = OLD.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.post_aggregates_post() OWNER TO lemmy;

--
-- Name: post_aggregates_score(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.post_aggregates_score() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        UPDATE
            post_aggregates pa
        SET
            score = score + NEW.score,
            upvotes = CASE WHEN NEW.score = 1 THEN
                upvotes + 1
            ELSE
                upvotes
            END,
            downvotes = CASE WHEN NEW.score = - 1 THEN
                downvotes + 1
            ELSE
                downvotes
            END,
            controversy_rank = controversy_rank (pa.upvotes + CASE WHEN NEW.score = 1 THEN
                    1
                ELSE
                    0
                END::numeric, pa.downvotes + CASE WHEN NEW.score = - 1 THEN
                    1
                ELSE
                    0
                END::numeric)
        WHERE
            pa.post_id = NEW.post_id;
    ELSIF (TG_OP = 'DELETE') THEN
        -- Join to post because that post may not exist anymore
        UPDATE
            post_aggregates pa
        SET
            score = score - OLD.score,
            upvotes = CASE WHEN OLD.score = 1 THEN
                upvotes - 1
            ELSE
                upvotes
            END,
            downvotes = CASE WHEN OLD.score = - 1 THEN
                downvotes - 1
            ELSE
                downvotes
            END,
            controversy_rank = controversy_rank (pa.upvotes + CASE WHEN NEW.score = 1 THEN
                    1
                ELSE
                    0
                END::numeric, pa.downvotes + CASE WHEN NEW.score = - 1 THEN
                    1
                ELSE
                    0
                END::numeric)
        FROM
            post p
        WHERE
            pa.post_id = p.id
            AND pa.post_id = OLD.post_id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.post_aggregates_score() OWNER TO lemmy;

--
-- Name: post_removed_resolve_reports(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.post_removed_resolve_reports() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE
        post_report
    SET
        resolved = TRUE,
        resolver_id = NEW.mod_person_id,
        updated = now()
    WHERE
        post_report.post_id = NEW.post_id;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.post_removed_resolve_reports() OWNER TO lemmy;

--
-- Name: scaled_rank(numeric, timestamp with time zone, numeric); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.scaled_rank(score numeric, published timestamp with time zone, users_active_month numeric) RETURNS double precision
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    AS $$
BEGIN
    -- Add 2 to avoid divide by zero errors
    -- Default for score = 1, active users = 1, and now, is (0.1728 / log(2 + 1)) = 0.3621
    -- There may need to be a scale factor multiplied to users_active_month, to make
    -- the log curve less pronounced. This can be tuned in the future.
    RETURN (hot_rank (score, published) / log(2 + users_active_month));
END;
$$;


ALTER FUNCTION public.scaled_rank(score numeric, published timestamp with time zone, users_active_month numeric) OWNER TO lemmy;

--
-- Name: site_aggregates_activity(text); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.site_aggregates_activity(i text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    count_ integer;
BEGIN
    SELECT
        count(*) INTO count_
    FROM (
        SELECT
            c.creator_id
        FROM
            comment c
            INNER JOIN person u ON c.creator_id = u.id
            INNER JOIN person pe ON c.creator_id = pe.id
        WHERE
            c.published > ('now'::timestamp - i::interval)
            AND u.local = TRUE
            AND pe.bot_account = FALSE
        UNION
        SELECT
            p.creator_id
        FROM
            post p
            INNER JOIN person u ON p.creator_id = u.id
            INNER JOIN person pe ON p.creator_id = pe.id
        WHERE
            p.published > ('now'::timestamp - i::interval)
            AND u.local = TRUE
            AND pe.bot_account = FALSE) a;
    RETURN count_;
END;
$$;


ALTER FUNCTION public.site_aggregates_activity(i text) OWNER TO lemmy;

--
-- Name: site_aggregates_comment_delete(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.site_aggregates_comment_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (was_removed_or_deleted (TG_OP, OLD, NEW)) THEN
        UPDATE
            site_aggregates sa
        SET
            comments = comments - 1
        FROM
            site s
        WHERE
            sa.site_id = s.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.site_aggregates_comment_delete() OWNER TO lemmy;

--
-- Name: site_aggregates_comment_insert(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.site_aggregates_comment_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (was_restored_or_created (TG_OP, OLD, NEW)) THEN
        UPDATE
            site_aggregates sa
        SET
            comments = comments + 1
        FROM
            site s
        WHERE
            sa.site_id = s.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.site_aggregates_comment_insert() OWNER TO lemmy;

--
-- Name: site_aggregates_community_delete(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.site_aggregates_community_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (was_removed_or_deleted (TG_OP, OLD, NEW)) THEN
        UPDATE
            site_aggregates sa
        SET
            communities = communities - 1
        FROM
            site s
        WHERE
            sa.site_id = s.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.site_aggregates_community_delete() OWNER TO lemmy;

--
-- Name: site_aggregates_community_insert(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.site_aggregates_community_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (was_restored_or_created (TG_OP, OLD, NEW)) THEN
        UPDATE
            site_aggregates sa
        SET
            communities = communities + 1
        FROM
            site s
        WHERE
            sa.site_id = s.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.site_aggregates_community_insert() OWNER TO lemmy;

--
-- Name: site_aggregates_person_delete(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.site_aggregates_person_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Join to site since the creator might not be there anymore
    UPDATE
        site_aggregates sa
    SET
        users = users - 1
    FROM
        site s
    WHERE
        sa.site_id = s.id;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.site_aggregates_person_delete() OWNER TO lemmy;

--
-- Name: site_aggregates_person_insert(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.site_aggregates_person_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE
        site_aggregates
    SET
        users = users + 1;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.site_aggregates_person_insert() OWNER TO lemmy;

--
-- Name: site_aggregates_post_delete(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.site_aggregates_post_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (was_removed_or_deleted (TG_OP, OLD, NEW)) THEN
        UPDATE
            site_aggregates sa
        SET
            posts = posts - 1
        FROM
            site s
        WHERE
            sa.site_id = s.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.site_aggregates_post_delete() OWNER TO lemmy;

--
-- Name: site_aggregates_post_insert(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.site_aggregates_post_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (was_restored_or_created (TG_OP, OLD, NEW)) THEN
        UPDATE
            site_aggregates sa
        SET
            posts = posts + 1
        FROM
            site s
        WHERE
            sa.site_id = s.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.site_aggregates_post_insert() OWNER TO lemmy;

--
-- Name: site_aggregates_site(); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.site_aggregates_site() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- we only ever want to have a single value in site_aggregate because the site_aggregate triggers update all rows in that table.
    -- a cleaner check would be to insert it for the local_site but that would break assumptions at least in the tests
    IF (TG_OP = 'INSERT') AND NOT EXISTS (
    SELECT
        id
    FROM
        site_aggregates
    LIMIT 1) THEN
        INSERT INTO site_aggregates (site_id)
            VALUES (NEW.id);
    ELSIF (TG_OP = 'DELETE') THEN
        DELETE FROM site_aggregates
        WHERE site_id = OLD.id;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.site_aggregates_site() OWNER TO lemmy;

--
-- Name: was_removed_or_deleted(text, record, record); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.was_removed_or_deleted(tg_op text, old record, new record) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        RETURN FALSE;
    END IF;
    IF (TG_OP = 'DELETE' AND OLD.deleted = 'f' AND OLD.removed = 'f') THEN
        RETURN TRUE;
    END IF;
    RETURN TG_OP = 'UPDATE'
        AND OLD.deleted = 'f'
        AND OLD.removed = 'f'
        AND (NEW.deleted = 't'
            OR NEW.removed = 't');
END
$$;


ALTER FUNCTION public.was_removed_or_deleted(tg_op text, old record, new record) OWNER TO lemmy;

--
-- Name: was_restored_or_created(text, record, record); Type: FUNCTION; Schema: public; Owner: lemmy
--

CREATE FUNCTION public.was_restored_or_created(tg_op text, old record, new record) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        RETURN FALSE;
    END IF;
    IF (TG_OP = 'INSERT') THEN
        RETURN TRUE;
    END IF;
    RETURN TG_OP = 'UPDATE'
        AND NEW.deleted = 'f'
        AND NEW.removed = 'f'
        AND (OLD.deleted = 't'
            OR OLD.removed = 't');
END
$$;


ALTER FUNCTION public.was_restored_or_created(tg_op text, old record, new record) OWNER TO lemmy;

--
-- Name: restore_views(character varying, character varying); Type: FUNCTION; Schema: utils; Owner: lemmy
--

CREATE FUNCTION utils.restore_views(p_view_schema character varying, p_view_name character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_curr record;
BEGIN
    FOR v_curr IN (
        SELECT
            ddl_to_run,
            id
        FROM
            utils.deps_saved_ddl
        WHERE
            view_schema = p_view_schema
            AND view_name = p_view_name
        ORDER BY
            id DESC)
            LOOP
                BEGIN
                    EXECUTE v_curr.ddl_to_run;
                    DELETE FROM utils.deps_saved_ddl
                    WHERE id = v_curr.id;
                EXCEPTION
                    WHEN OTHERS THEN
                        -- keep looping, but please check for errors or remove left overs to handle manually
                END;
    END LOOP;
END;

$$;


ALTER FUNCTION utils.restore_views(p_view_schema character varying, p_view_name character varying) OWNER TO lemmy;

--
-- Name: save_and_drop_views(name, name); Type: FUNCTION; Schema: utils; Owner: lemmy
--

CREATE FUNCTION utils.save_and_drop_views(p_view_schema name, p_view_name name) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_curr record;
BEGIN
    FOR v_curr IN (
        SELECT
            obj_schema,
            obj_name,
            obj_type
        FROM ( WITH RECURSIVE recursive_deps (
                obj_schema,
                obj_name,
                obj_type,
                depth
) AS (
                SELECT
                    p_view_schema::name,
                    p_view_name,
                    NULL::varchar,
                    0
                UNION
                SELECT
                    dep_schema::varchar,
                    dep_name::varchar,
                    dep_type::varchar,
                    recursive_deps.depth + 1
                FROM (
                    SELECT
                        ref_nsp.nspname ref_schema,
                        ref_cl.relname ref_name,
                        rwr_cl.relkind dep_type,
                        rwr_nsp.nspname dep_schema,
                        rwr_cl.relname dep_name
                    FROM
                        pg_depend dep
                        JOIN pg_class ref_cl ON dep.refobjid = ref_cl.oid
                        JOIN pg_namespace ref_nsp ON ref_cl.relnamespace = ref_nsp.oid
                        JOIN pg_rewrite rwr ON dep.objid = rwr.oid
                        JOIN pg_class rwr_cl ON rwr.ev_class = rwr_cl.oid
                        JOIN pg_namespace rwr_nsp ON rwr_cl.relnamespace = rwr_nsp.oid
                    WHERE
                        dep.deptype = 'n'
                        AND dep.classid = 'pg_rewrite'::regclass) deps
                    JOIN recursive_deps ON deps.ref_schema = recursive_deps.obj_schema
                        AND deps.ref_name = recursive_deps.obj_name
                WHERE (deps.ref_schema != deps.dep_schema
                    OR deps.ref_name != deps.dep_name))
            SELECT
                obj_schema,
                obj_name,
                obj_type,
                depth
            FROM
                recursive_deps
            WHERE
                depth > 0) t
        GROUP BY
            obj_schema,
            obj_name,
            obj_type
        ORDER BY
            max(depth) DESC)
            LOOP
                IF v_curr.obj_type = 'v' THEN
                    INSERT INTO utils.deps_saved_ddl (view_schema, view_name, ddl_to_run)
                    SELECT
                        p_view_schema,
                        p_view_name,
                        'CREATE VIEW ' || v_curr.obj_schema || '.' || v_curr.obj_name || ' AS ' || view_definition
                    FROM
                        information_schema.views
                    WHERE
                        table_schema = v_curr.obj_schema
                        AND table_name = v_curr.obj_name;
                    EXECUTE 'DROP VIEW' || ' ' || v_curr.obj_schema || '.' || v_curr.obj_name;
                END IF;
            END LOOP;
END;
$$;


ALTER FUNCTION utils.save_and_drop_views(p_view_schema name, p_view_name name) OWNER TO lemmy;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: __diesel_schema_migrations; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.__diesel_schema_migrations (
    version character varying(50) NOT NULL,
    run_on timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE public.__diesel_schema_migrations OWNER TO lemmy;

--
-- Name: admin_purge_comment; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.admin_purge_comment (
    id integer NOT NULL,
    admin_person_id integer NOT NULL,
    post_id integer NOT NULL,
    reason text,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.admin_purge_comment OWNER TO lemmy;

--
-- Name: admin_purge_comment_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.admin_purge_comment_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.admin_purge_comment_id_seq OWNER TO lemmy;

--
-- Name: admin_purge_comment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.admin_purge_comment_id_seq OWNED BY public.admin_purge_comment.id;


--
-- Name: admin_purge_community; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.admin_purge_community (
    id integer NOT NULL,
    admin_person_id integer NOT NULL,
    reason text,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.admin_purge_community OWNER TO lemmy;

--
-- Name: admin_purge_community_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.admin_purge_community_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.admin_purge_community_id_seq OWNER TO lemmy;

--
-- Name: admin_purge_community_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.admin_purge_community_id_seq OWNED BY public.admin_purge_community.id;


--
-- Name: admin_purge_person; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.admin_purge_person (
    id integer NOT NULL,
    admin_person_id integer NOT NULL,
    reason text,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.admin_purge_person OWNER TO lemmy;

--
-- Name: admin_purge_person_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.admin_purge_person_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.admin_purge_person_id_seq OWNER TO lemmy;

--
-- Name: admin_purge_person_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.admin_purge_person_id_seq OWNED BY public.admin_purge_person.id;


--
-- Name: admin_purge_post; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.admin_purge_post (
    id integer NOT NULL,
    admin_person_id integer NOT NULL,
    community_id integer NOT NULL,
    reason text,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.admin_purge_post OWNER TO lemmy;

--
-- Name: admin_purge_post_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.admin_purge_post_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.admin_purge_post_id_seq OWNER TO lemmy;

--
-- Name: admin_purge_post_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.admin_purge_post_id_seq OWNED BY public.admin_purge_post.id;


--
-- Name: captcha_answer; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.captcha_answer (
    id integer NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    answer text NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.captcha_answer OWNER TO lemmy;

--
-- Name: captcha_answer_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.captcha_answer_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.captcha_answer_id_seq OWNER TO lemmy;

--
-- Name: captcha_answer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.captcha_answer_id_seq OWNED BY public.captcha_answer.id;


--
-- Name: comment; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.comment (
    id integer NOT NULL,
    creator_id integer NOT NULL,
    post_id integer NOT NULL,
    content text NOT NULL,
    removed boolean DEFAULT false NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone,
    deleted boolean DEFAULT false NOT NULL,
    ap_id character varying(255) DEFAULT public.generate_unique_changeme() NOT NULL,
    local boolean DEFAULT true NOT NULL,
    path public.ltree DEFAULT '0'::public.ltree NOT NULL,
    distinguished boolean DEFAULT false NOT NULL,
    language_id integer DEFAULT 0 NOT NULL,
    bid integer
);


ALTER TABLE public.comment OWNER TO lemmy;

--
-- Name: comment_aggregates; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.comment_aggregates (
    id integer NOT NULL,
    comment_id integer NOT NULL,
    score bigint DEFAULT 0 NOT NULL,
    upvotes bigint DEFAULT 0 NOT NULL,
    downvotes bigint DEFAULT 0 NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    child_count integer DEFAULT 0 NOT NULL,
    hot_rank double precision DEFAULT 0.1728 NOT NULL,
    controversy_rank double precision DEFAULT 0 NOT NULL
);


ALTER TABLE public.comment_aggregates OWNER TO lemmy;

--
-- Name: comment_aggregates_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.comment_aggregates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.comment_aggregates_id_seq OWNER TO lemmy;

--
-- Name: comment_aggregates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.comment_aggregates_id_seq OWNED BY public.comment_aggregates.id;


--
-- Name: comment_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.comment_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.comment_id_seq OWNER TO lemmy;

--
-- Name: comment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.comment_id_seq OWNED BY public.comment.id;


--
-- Name: comment_like; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.comment_like (
    id integer NOT NULL,
    person_id integer NOT NULL,
    comment_id integer NOT NULL,
    post_id integer NOT NULL,
    score smallint NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.comment_like OWNER TO lemmy;

--
-- Name: comment_like_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.comment_like_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.comment_like_id_seq OWNER TO lemmy;

--
-- Name: comment_like_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.comment_like_id_seq OWNED BY public.comment_like.id;


--
-- Name: comment_reply; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.comment_reply (
    id integer NOT NULL,
    recipient_id integer NOT NULL,
    comment_id integer NOT NULL,
    read boolean DEFAULT false NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.comment_reply OWNER TO lemmy;

--
-- Name: comment_reply_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.comment_reply_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.comment_reply_id_seq OWNER TO lemmy;

--
-- Name: comment_reply_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.comment_reply_id_seq OWNED BY public.comment_reply.id;


--
-- Name: comment_report; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.comment_report (
    id integer NOT NULL,
    creator_id integer NOT NULL,
    comment_id integer NOT NULL,
    original_comment_text text NOT NULL,
    reason text NOT NULL,
    resolved boolean DEFAULT false NOT NULL,
    resolver_id integer,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone
);


ALTER TABLE public.comment_report OWNER TO lemmy;

--
-- Name: comment_report_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.comment_report_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.comment_report_id_seq OWNER TO lemmy;

--
-- Name: comment_report_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.comment_report_id_seq OWNED BY public.comment_report.id;


--
-- Name: comment_saved; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.comment_saved (
    id integer NOT NULL,
    comment_id integer NOT NULL,
    person_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.comment_saved OWNER TO lemmy;

--
-- Name: comment_saved_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.comment_saved_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.comment_saved_id_seq OWNER TO lemmy;

--
-- Name: comment_saved_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.comment_saved_id_seq OWNED BY public.comment_saved.id;


--
-- Name: community; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.community (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    removed boolean DEFAULT false NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone,
    deleted boolean DEFAULT false NOT NULL,
    nsfw boolean DEFAULT false NOT NULL,
    actor_id character varying(255) DEFAULT public.generate_unique_changeme() NOT NULL,
    local boolean DEFAULT true NOT NULL,
    private_key text,
    public_key text NOT NULL,
    last_refreshed_at timestamp with time zone DEFAULT now() NOT NULL,
    icon text,
    banner text,
    followers_url character varying(255) DEFAULT public.generate_unique_changeme() NOT NULL,
    inbox_url character varying(255) DEFAULT public.generate_unique_changeme() NOT NULL,
    shared_inbox_url character varying(255),
    hidden boolean DEFAULT false NOT NULL,
    posting_restricted_to_mods boolean DEFAULT false NOT NULL,
    instance_id integer NOT NULL,
    moderators_url character varying(255),
    featured_url character varying(255)
);


ALTER TABLE public.community OWNER TO lemmy;

--
-- Name: community_aggregates; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.community_aggregates (
    id integer NOT NULL,
    community_id integer NOT NULL,
    subscribers bigint DEFAULT 0 NOT NULL,
    posts bigint DEFAULT 0 NOT NULL,
    comments bigint DEFAULT 0 NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    users_active_day bigint DEFAULT 0 NOT NULL,
    users_active_week bigint DEFAULT 0 NOT NULL,
    users_active_month bigint DEFAULT 0 NOT NULL,
    users_active_half_year bigint DEFAULT 0 NOT NULL,
    hot_rank double precision DEFAULT 0.1728 NOT NULL
);


ALTER TABLE public.community_aggregates OWNER TO lemmy;

--
-- Name: community_aggregates_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.community_aggregates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.community_aggregates_id_seq OWNER TO lemmy;

--
-- Name: community_aggregates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.community_aggregates_id_seq OWNED BY public.community_aggregates.id;


--
-- Name: community_block; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.community_block (
    id integer NOT NULL,
    person_id integer NOT NULL,
    community_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.community_block OWNER TO lemmy;

--
-- Name: community_block_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.community_block_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.community_block_id_seq OWNER TO lemmy;

--
-- Name: community_block_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.community_block_id_seq OWNED BY public.community_block.id;


--
-- Name: community_follower; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.community_follower (
    id integer NOT NULL,
    community_id integer NOT NULL,
    person_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    pending boolean DEFAULT false NOT NULL
);


ALTER TABLE public.community_follower OWNER TO lemmy;

--
-- Name: community_follower_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.community_follower_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.community_follower_id_seq OWNER TO lemmy;

--
-- Name: community_follower_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.community_follower_id_seq OWNED BY public.community_follower.id;


--
-- Name: community_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.community_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.community_id_seq OWNER TO lemmy;

--
-- Name: community_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.community_id_seq OWNED BY public.community.id;


--
-- Name: community_language; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.community_language (
    id integer NOT NULL,
    community_id integer NOT NULL,
    language_id integer NOT NULL
);


ALTER TABLE public.community_language OWNER TO lemmy;

--
-- Name: community_language_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.community_language_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.community_language_id_seq OWNER TO lemmy;

--
-- Name: community_language_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.community_language_id_seq OWNED BY public.community_language.id;


--
-- Name: community_moderator; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.community_moderator (
    id integer NOT NULL,
    community_id integer NOT NULL,
    person_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.community_moderator OWNER TO lemmy;

--
-- Name: community_moderator_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.community_moderator_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.community_moderator_id_seq OWNER TO lemmy;

--
-- Name: community_moderator_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.community_moderator_id_seq OWNED BY public.community_moderator.id;


--
-- Name: community_person_ban; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.community_person_ban (
    id integer NOT NULL,
    community_id integer NOT NULL,
    person_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    expires timestamp with time zone
);


ALTER TABLE public.community_person_ban OWNER TO lemmy;

--
-- Name: community_person_ban_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.community_person_ban_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.community_person_ban_id_seq OWNER TO lemmy;

--
-- Name: community_person_ban_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.community_person_ban_id_seq OWNED BY public.community_person_ban.id;


--
-- Name: custom_emoji; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.custom_emoji (
    id integer NOT NULL,
    local_site_id integer NOT NULL,
    shortcode character varying(128) NOT NULL,
    image_url text NOT NULL,
    alt_text text NOT NULL,
    category text NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone
);


ALTER TABLE public.custom_emoji OWNER TO lemmy;

--
-- Name: custom_emoji_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.custom_emoji_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.custom_emoji_id_seq OWNER TO lemmy;

--
-- Name: custom_emoji_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.custom_emoji_id_seq OWNED BY public.custom_emoji.id;


--
-- Name: custom_emoji_keyword; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.custom_emoji_keyword (
    id integer NOT NULL,
    custom_emoji_id integer NOT NULL,
    keyword character varying(128) NOT NULL
);


ALTER TABLE public.custom_emoji_keyword OWNER TO lemmy;

--
-- Name: custom_emoji_keyword_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.custom_emoji_keyword_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.custom_emoji_keyword_id_seq OWNER TO lemmy;

--
-- Name: custom_emoji_keyword_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.custom_emoji_keyword_id_seq OWNED BY public.custom_emoji_keyword.id;


--
-- Name: email_verification; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.email_verification (
    id integer NOT NULL,
    local_user_id integer NOT NULL,
    email text NOT NULL,
    verification_token text NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.email_verification OWNER TO lemmy;

--
-- Name: email_verification_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.email_verification_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.email_verification_id_seq OWNER TO lemmy;

--
-- Name: email_verification_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.email_verification_id_seq OWNED BY public.email_verification.id;


--
-- Name: federation_allowlist; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.federation_allowlist (
    id integer NOT NULL,
    instance_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone
);


ALTER TABLE public.federation_allowlist OWNER TO lemmy;

--
-- Name: federation_allowlist_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.federation_allowlist_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.federation_allowlist_id_seq OWNER TO lemmy;

--
-- Name: federation_allowlist_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.federation_allowlist_id_seq OWNED BY public.federation_allowlist.id;


--
-- Name: federation_blocklist; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.federation_blocklist (
    id integer NOT NULL,
    instance_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone
);


ALTER TABLE public.federation_blocklist OWNER TO lemmy;

--
-- Name: federation_blocklist_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.federation_blocklist_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.federation_blocklist_id_seq OWNER TO lemmy;

--
-- Name: federation_blocklist_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.federation_blocklist_id_seq OWNED BY public.federation_blocklist.id;


--
-- Name: federation_queue_state; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.federation_queue_state (
    id integer NOT NULL,
    instance_id integer NOT NULL,
    last_successful_id bigint NOT NULL,
    fail_count integer NOT NULL,
    last_retry timestamp with time zone NOT NULL
);


ALTER TABLE public.federation_queue_state OWNER TO lemmy;

--
-- Name: federation_queue_state_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.federation_queue_state_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.federation_queue_state_id_seq OWNER TO lemmy;

--
-- Name: federation_queue_state_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.federation_queue_state_id_seq OWNED BY public.federation_queue_state.id;


--
-- Name: image_upload; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.image_upload (
    id integer NOT NULL,
    local_user_id integer NOT NULL,
    pictrs_alias text NOT NULL,
    pictrs_delete_token text NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.image_upload OWNER TO lemmy;

--
-- Name: image_upload_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.image_upload_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.image_upload_id_seq OWNER TO lemmy;

--
-- Name: image_upload_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.image_upload_id_seq OWNED BY public.image_upload.id;


--
-- Name: instance; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.instance (
    id integer NOT NULL,
    domain character varying(255) NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone,
    software character varying(255),
    version character varying(255)
);


ALTER TABLE public.instance OWNER TO lemmy;

--
-- Name: instance_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.instance_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.instance_id_seq OWNER TO lemmy;

--
-- Name: instance_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.instance_id_seq OWNED BY public.instance.id;


--
-- Name: language; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.language (
    id integer NOT NULL,
    code character varying(3) NOT NULL,
    name text NOT NULL
);


ALTER TABLE public.language OWNER TO lemmy;

--
-- Name: language_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.language_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.language_id_seq OWNER TO lemmy;

--
-- Name: language_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.language_id_seq OWNED BY public.language.id;


--
-- Name: local_site; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.local_site (
    id integer NOT NULL,
    site_id integer NOT NULL,
    site_setup boolean DEFAULT false NOT NULL,
    enable_downvotes boolean DEFAULT true NOT NULL,
    enable_nsfw boolean DEFAULT true NOT NULL,
    community_creation_admin_only boolean DEFAULT false NOT NULL,
    require_email_verification boolean DEFAULT false NOT NULL,
    application_question text DEFAULT 'to verify that you are human, please explain why you want to create an account on this site'::text,
    private_instance boolean DEFAULT false NOT NULL,
    default_theme text DEFAULT 'browser'::text NOT NULL,
    default_post_listing_type public.listing_type_enum DEFAULT 'Local'::public.listing_type_enum NOT NULL,
    legal_information text,
    hide_modlog_mod_names boolean DEFAULT true NOT NULL,
    application_email_admins boolean DEFAULT false NOT NULL,
    slur_filter_regex text,
    actor_name_max_length integer DEFAULT 20 NOT NULL,
    federation_enabled boolean DEFAULT true NOT NULL,
    captcha_enabled boolean DEFAULT false NOT NULL,
    captcha_difficulty character varying(255) DEFAULT 'medium'::character varying NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone,
    registration_mode public.registration_mode_enum DEFAULT 'RequireApplication'::public.registration_mode_enum NOT NULL,
    reports_email_admins boolean DEFAULT false NOT NULL
);


ALTER TABLE public.local_site OWNER TO lemmy;

--
-- Name: local_site_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.local_site_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.local_site_id_seq OWNER TO lemmy;

--
-- Name: local_site_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.local_site_id_seq OWNED BY public.local_site.id;


--
-- Name: local_site_rate_limit; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.local_site_rate_limit (
    id integer NOT NULL,
    local_site_id integer NOT NULL,
    message integer DEFAULT 180 NOT NULL,
    message_per_second integer DEFAULT 60 NOT NULL,
    post integer DEFAULT 6 NOT NULL,
    post_per_second integer DEFAULT 600 NOT NULL,
    register integer DEFAULT 3 NOT NULL,
    register_per_second integer DEFAULT 3600 NOT NULL,
    image integer DEFAULT 6 NOT NULL,
    image_per_second integer DEFAULT 3600 NOT NULL,
    comment integer DEFAULT 6 NOT NULL,
    comment_per_second integer DEFAULT 600 NOT NULL,
    search integer DEFAULT 60 NOT NULL,
    search_per_second integer DEFAULT 600 NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone
);


ALTER TABLE public.local_site_rate_limit OWNER TO lemmy;

--
-- Name: local_site_rate_limit_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.local_site_rate_limit_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.local_site_rate_limit_id_seq OWNER TO lemmy;

--
-- Name: local_site_rate_limit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.local_site_rate_limit_id_seq OWNED BY public.local_site_rate_limit.id;


--
-- Name: local_user; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.local_user (
    id integer NOT NULL,
    person_id integer NOT NULL,
    password_encrypted text NOT NULL,
    email text,
    show_nsfw boolean DEFAULT false NOT NULL,
    theme text DEFAULT 'browser'::text NOT NULL,
    default_sort_type public.sort_type_enum DEFAULT 'Active'::public.sort_type_enum NOT NULL,
    default_listing_type public.listing_type_enum DEFAULT 'Local'::public.listing_type_enum NOT NULL,
    interface_language character varying(20) DEFAULT 'browser'::character varying NOT NULL,
    show_avatars boolean DEFAULT true NOT NULL,
    send_notifications_to_email boolean DEFAULT false NOT NULL,
    validator_time timestamp with time zone DEFAULT now() NOT NULL,
    show_scores boolean DEFAULT true NOT NULL,
    show_bot_accounts boolean DEFAULT true NOT NULL,
    show_read_posts boolean DEFAULT true NOT NULL,
    show_new_post_notifs boolean DEFAULT false NOT NULL,
    email_verified boolean DEFAULT false NOT NULL,
    accepted_application boolean DEFAULT false NOT NULL,
    totp_2fa_secret text,
    totp_2fa_url text,
    open_links_in_new_tab boolean DEFAULT false NOT NULL,
    blur_nsfw boolean DEFAULT true NOT NULL,
    auto_expand boolean DEFAULT false NOT NULL,
    infinite_scroll_enabled boolean DEFAULT false NOT NULL,
    admin boolean DEFAULT false NOT NULL,
    post_listing_mode public.post_listing_mode_enum DEFAULT 'List'::public.post_listing_mode_enum NOT NULL
);


ALTER TABLE public.local_user OWNER TO lemmy;

--
-- Name: local_user_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.local_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.local_user_id_seq OWNER TO lemmy;

--
-- Name: local_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.local_user_id_seq OWNED BY public.local_user.id;


--
-- Name: local_user_language; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.local_user_language (
    id integer NOT NULL,
    local_user_id integer NOT NULL,
    language_id integer NOT NULL
);


ALTER TABLE public.local_user_language OWNER TO lemmy;

--
-- Name: local_user_language_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.local_user_language_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.local_user_language_id_seq OWNER TO lemmy;

--
-- Name: local_user_language_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.local_user_language_id_seq OWNED BY public.local_user_language.id;


--
-- Name: mod_add; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_add (
    id integer NOT NULL,
    mod_person_id integer NOT NULL,
    other_person_id integer NOT NULL,
    removed boolean DEFAULT false NOT NULL,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.mod_add OWNER TO lemmy;

--
-- Name: mod_add_community; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_add_community (
    id integer NOT NULL,
    mod_person_id integer NOT NULL,
    other_person_id integer NOT NULL,
    community_id integer NOT NULL,
    removed boolean DEFAULT false NOT NULL,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.mod_add_community OWNER TO lemmy;

--
-- Name: mod_add_community_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_add_community_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_add_community_id_seq OWNER TO lemmy;

--
-- Name: mod_add_community_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_add_community_id_seq OWNED BY public.mod_add_community.id;


--
-- Name: mod_add_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_add_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_add_id_seq OWNER TO lemmy;

--
-- Name: mod_add_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_add_id_seq OWNED BY public.mod_add.id;


--
-- Name: mod_ban; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_ban (
    id integer NOT NULL,
    mod_person_id integer NOT NULL,
    other_person_id integer NOT NULL,
    reason text,
    banned boolean DEFAULT true NOT NULL,
    expires timestamp with time zone,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.mod_ban OWNER TO lemmy;

--
-- Name: mod_ban_from_community; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_ban_from_community (
    id integer NOT NULL,
    mod_person_id integer NOT NULL,
    other_person_id integer NOT NULL,
    community_id integer NOT NULL,
    reason text,
    banned boolean DEFAULT true NOT NULL,
    expires timestamp with time zone,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.mod_ban_from_community OWNER TO lemmy;

--
-- Name: mod_ban_from_community_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_ban_from_community_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_ban_from_community_id_seq OWNER TO lemmy;

--
-- Name: mod_ban_from_community_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_ban_from_community_id_seq OWNED BY public.mod_ban_from_community.id;


--
-- Name: mod_ban_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_ban_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_ban_id_seq OWNER TO lemmy;

--
-- Name: mod_ban_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_ban_id_seq OWNED BY public.mod_ban.id;


--
-- Name: mod_feature_post; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_feature_post (
    id integer NOT NULL,
    mod_person_id integer NOT NULL,
    post_id integer NOT NULL,
    featured boolean DEFAULT true NOT NULL,
    when_ timestamp with time zone DEFAULT now() NOT NULL,
    is_featured_community boolean DEFAULT true NOT NULL
);


ALTER TABLE public.mod_feature_post OWNER TO lemmy;

--
-- Name: mod_hide_community; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_hide_community (
    id integer NOT NULL,
    community_id integer NOT NULL,
    mod_person_id integer NOT NULL,
    when_ timestamp with time zone DEFAULT now() NOT NULL,
    reason text,
    hidden boolean DEFAULT false NOT NULL
);


ALTER TABLE public.mod_hide_community OWNER TO lemmy;

--
-- Name: mod_hide_community_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_hide_community_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_hide_community_id_seq OWNER TO lemmy;

--
-- Name: mod_hide_community_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_hide_community_id_seq OWNED BY public.mod_hide_community.id;


--
-- Name: mod_lock_post; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_lock_post (
    id integer NOT NULL,
    mod_person_id integer NOT NULL,
    post_id integer NOT NULL,
    locked boolean DEFAULT true NOT NULL,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.mod_lock_post OWNER TO lemmy;

--
-- Name: mod_lock_post_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_lock_post_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_lock_post_id_seq OWNER TO lemmy;

--
-- Name: mod_lock_post_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_lock_post_id_seq OWNED BY public.mod_lock_post.id;


--
-- Name: mod_remove_comment; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_remove_comment (
    id integer NOT NULL,
    mod_person_id integer NOT NULL,
    comment_id integer NOT NULL,
    reason text,
    removed boolean DEFAULT true NOT NULL,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.mod_remove_comment OWNER TO lemmy;

--
-- Name: mod_remove_comment_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_remove_comment_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_remove_comment_id_seq OWNER TO lemmy;

--
-- Name: mod_remove_comment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_remove_comment_id_seq OWNED BY public.mod_remove_comment.id;


--
-- Name: mod_remove_community; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_remove_community (
    id integer NOT NULL,
    mod_person_id integer NOT NULL,
    community_id integer NOT NULL,
    reason text,
    removed boolean DEFAULT true NOT NULL,
    expires timestamp with time zone,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.mod_remove_community OWNER TO lemmy;

--
-- Name: mod_remove_community_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_remove_community_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_remove_community_id_seq OWNER TO lemmy;

--
-- Name: mod_remove_community_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_remove_community_id_seq OWNED BY public.mod_remove_community.id;


--
-- Name: mod_remove_post; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_remove_post (
    id integer NOT NULL,
    mod_person_id integer NOT NULL,
    post_id integer NOT NULL,
    reason text,
    removed boolean DEFAULT true NOT NULL,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.mod_remove_post OWNER TO lemmy;

--
-- Name: mod_remove_post_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_remove_post_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_remove_post_id_seq OWNER TO lemmy;

--
-- Name: mod_remove_post_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_remove_post_id_seq OWNED BY public.mod_remove_post.id;


--
-- Name: mod_sticky_post_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_sticky_post_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_sticky_post_id_seq OWNER TO lemmy;

--
-- Name: mod_sticky_post_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_sticky_post_id_seq OWNED BY public.mod_feature_post.id;


--
-- Name: mod_transfer_community; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.mod_transfer_community (
    id integer NOT NULL,
    mod_person_id integer NOT NULL,
    other_person_id integer NOT NULL,
    community_id integer NOT NULL,
    when_ timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.mod_transfer_community OWNER TO lemmy;

--
-- Name: mod_transfer_community_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.mod_transfer_community_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mod_transfer_community_id_seq OWNER TO lemmy;

--
-- Name: mod_transfer_community_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.mod_transfer_community_id_seq OWNED BY public.mod_transfer_community.id;


--
-- Name: password_reset_request; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.password_reset_request (
    id integer NOT NULL,
    token text NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    local_user_id integer NOT NULL
);


ALTER TABLE public.password_reset_request OWNER TO lemmy;

--
-- Name: password_reset_request_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.password_reset_request_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.password_reset_request_id_seq OWNER TO lemmy;

--
-- Name: password_reset_request_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.password_reset_request_id_seq OWNED BY public.password_reset_request.id;


--
-- Name: person; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.person (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    display_name character varying(255),
    avatar text,
    banned boolean DEFAULT false NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone,
    actor_id character varying(255) DEFAULT public.generate_unique_changeme() NOT NULL,
    bio text,
    local boolean DEFAULT true NOT NULL,
    private_key text,
    public_key text NOT NULL,
    last_refreshed_at timestamp with time zone DEFAULT now() NOT NULL,
    banner text,
    deleted boolean DEFAULT false NOT NULL,
    inbox_url character varying(255) DEFAULT public.generate_unique_changeme() NOT NULL,
    shared_inbox_url character varying(255),
    matrix_user_id text,
    bot_account boolean DEFAULT false NOT NULL,
    ban_expires timestamp with time zone,
    instance_id integer NOT NULL
);


ALTER TABLE public.person OWNER TO lemmy;

--
-- Name: person_aggregates; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.person_aggregates (
    id integer NOT NULL,
    person_id integer NOT NULL,
    post_count bigint DEFAULT 0 NOT NULL,
    post_score bigint DEFAULT 0 NOT NULL,
    comment_count bigint DEFAULT 0 NOT NULL,
    comment_score bigint DEFAULT 0 NOT NULL
);


ALTER TABLE public.person_aggregates OWNER TO lemmy;

--
-- Name: person_aggregates_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.person_aggregates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.person_aggregates_id_seq OWNER TO lemmy;

--
-- Name: person_aggregates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.person_aggregates_id_seq OWNED BY public.person_aggregates.id;


--
-- Name: person_ban; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.person_ban (
    id integer NOT NULL,
    person_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.person_ban OWNER TO lemmy;

--
-- Name: person_ban_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.person_ban_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.person_ban_id_seq OWNER TO lemmy;

--
-- Name: person_ban_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.person_ban_id_seq OWNED BY public.person_ban.id;


--
-- Name: person_block; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.person_block (
    id integer NOT NULL,
    person_id integer NOT NULL,
    target_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.person_block OWNER TO lemmy;

--
-- Name: person_block_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.person_block_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.person_block_id_seq OWNER TO lemmy;

--
-- Name: person_block_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.person_block_id_seq OWNED BY public.person_block.id;


--
-- Name: person_follower; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.person_follower (
    id integer NOT NULL,
    person_id integer NOT NULL,
    follower_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    pending boolean NOT NULL
);


ALTER TABLE public.person_follower OWNER TO lemmy;

--
-- Name: person_follower_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.person_follower_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.person_follower_id_seq OWNER TO lemmy;

--
-- Name: person_follower_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.person_follower_id_seq OWNED BY public.person_follower.id;


--
-- Name: person_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.person_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.person_id_seq OWNER TO lemmy;

--
-- Name: person_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.person_id_seq OWNED BY public.person.id;


--
-- Name: person_mention; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.person_mention (
    id integer NOT NULL,
    recipient_id integer NOT NULL,
    comment_id integer NOT NULL,
    read boolean DEFAULT false NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.person_mention OWNER TO lemmy;

--
-- Name: person_mention_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.person_mention_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.person_mention_id_seq OWNER TO lemmy;

--
-- Name: person_mention_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.person_mention_id_seq OWNED BY public.person_mention.id;


--
-- Name: person_post_aggregates; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.person_post_aggregates (
    id integer NOT NULL,
    person_id integer NOT NULL,
    post_id integer NOT NULL,
    read_comments bigint DEFAULT 0 NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.person_post_aggregates OWNER TO lemmy;

--
-- Name: person_post_aggregates_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.person_post_aggregates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.person_post_aggregates_id_seq OWNER TO lemmy;

--
-- Name: person_post_aggregates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.person_post_aggregates_id_seq OWNED BY public.person_post_aggregates.id;


--
-- Name: post; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.post (
    id integer NOT NULL,
    name character varying(200) NOT NULL,
    url character varying(512),
    body text,
    creator_id integer NOT NULL,
    community_id integer NOT NULL,
    removed boolean DEFAULT false NOT NULL,
    locked boolean DEFAULT false NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone,
    deleted boolean DEFAULT false NOT NULL,
    nsfw boolean DEFAULT false NOT NULL,
    embed_title text,
    embed_description text,
    thumbnail_url text,
    ap_id character varying(255) DEFAULT public.generate_unique_changeme() NOT NULL,
    local boolean DEFAULT true NOT NULL,
    embed_video_url text,
    language_id integer DEFAULT 0 NOT NULL,
    featured_community boolean DEFAULT false NOT NULL,
    featured_local boolean DEFAULT false NOT NULL,
    pickup_location text,
    pickup_time timestamp with time zone,
    pickup_contact text,
    pickup_notes text,
    dropoff_location text,
    dropoff_time timestamp with time zone,
    dropoff_contact text,
    dropoff_notes text
);


ALTER TABLE public.post OWNER TO lemmy;

--
-- Name: post_aggregates; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.post_aggregates (
    id integer NOT NULL,
    post_id integer NOT NULL,
    comments bigint DEFAULT 0 NOT NULL,
    score bigint DEFAULT 0 NOT NULL,
    upvotes bigint DEFAULT 0 NOT NULL,
    downvotes bigint DEFAULT 0 NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    newest_comment_time_necro timestamp with time zone DEFAULT now() NOT NULL,
    newest_comment_time timestamp with time zone DEFAULT now() NOT NULL,
    featured_community boolean DEFAULT false NOT NULL,
    featured_local boolean DEFAULT false NOT NULL,
    hot_rank double precision DEFAULT 0.1728 NOT NULL,
    hot_rank_active double precision DEFAULT 0.1728 NOT NULL,
    community_id integer NOT NULL,
    creator_id integer NOT NULL,
    controversy_rank double precision DEFAULT 0 NOT NULL,
    scaled_rank double precision DEFAULT 0.3621 NOT NULL
);


ALTER TABLE public.post_aggregates OWNER TO lemmy;

--
-- Name: post_aggregates_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.post_aggregates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.post_aggregates_id_seq OWNER TO lemmy;

--
-- Name: post_aggregates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.post_aggregates_id_seq OWNED BY public.post_aggregates.id;


--
-- Name: post_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.post_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.post_id_seq OWNER TO lemmy;

--
-- Name: post_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.post_id_seq OWNED BY public.post.id;


--
-- Name: post_like; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.post_like (
    id integer NOT NULL,
    post_id integer NOT NULL,
    person_id integer NOT NULL,
    score smallint NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.post_like OWNER TO lemmy;

--
-- Name: post_like_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.post_like_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.post_like_id_seq OWNER TO lemmy;

--
-- Name: post_like_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.post_like_id_seq OWNED BY public.post_like.id;


--
-- Name: post_read; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.post_read (
    id integer NOT NULL,
    post_id integer NOT NULL,
    person_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.post_read OWNER TO lemmy;

--
-- Name: post_read_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.post_read_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.post_read_id_seq OWNER TO lemmy;

--
-- Name: post_read_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.post_read_id_seq OWNED BY public.post_read.id;


--
-- Name: post_report; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.post_report (
    id integer NOT NULL,
    creator_id integer NOT NULL,
    post_id integer NOT NULL,
    original_post_name character varying(200) NOT NULL,
    original_post_url text,
    original_post_body text,
    reason text NOT NULL,
    resolved boolean DEFAULT false NOT NULL,
    resolver_id integer,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone
);


ALTER TABLE public.post_report OWNER TO lemmy;

--
-- Name: post_report_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.post_report_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.post_report_id_seq OWNER TO lemmy;

--
-- Name: post_report_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.post_report_id_seq OWNED BY public.post_report.id;


--
-- Name: post_saved; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.post_saved (
    id integer NOT NULL,
    post_id integer NOT NULL,
    person_id integer NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.post_saved OWNER TO lemmy;

--
-- Name: post_saved_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.post_saved_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.post_saved_id_seq OWNER TO lemmy;

--
-- Name: post_saved_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.post_saved_id_seq OWNED BY public.post_saved.id;


--
-- Name: private_message; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.private_message (
    id integer NOT NULL,
    creator_id integer NOT NULL,
    recipient_id integer NOT NULL,
    content text NOT NULL,
    deleted boolean DEFAULT false NOT NULL,
    read boolean DEFAULT false NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone,
    ap_id character varying(255) DEFAULT public.generate_unique_changeme() NOT NULL,
    local boolean DEFAULT true NOT NULL
);


ALTER TABLE public.private_message OWNER TO lemmy;

--
-- Name: private_message_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.private_message_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.private_message_id_seq OWNER TO lemmy;

--
-- Name: private_message_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.private_message_id_seq OWNED BY public.private_message.id;


--
-- Name: private_message_report; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.private_message_report (
    id integer NOT NULL,
    creator_id integer NOT NULL,
    private_message_id integer NOT NULL,
    original_pm_text text NOT NULL,
    reason text NOT NULL,
    resolved boolean DEFAULT false NOT NULL,
    resolver_id integer,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone
);


ALTER TABLE public.private_message_report OWNER TO lemmy;

--
-- Name: private_message_report_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.private_message_report_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.private_message_report_id_seq OWNER TO lemmy;

--
-- Name: private_message_report_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.private_message_report_id_seq OWNED BY public.private_message_report.id;


--
-- Name: received_activity; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.received_activity (
    id bigint NOT NULL,
    ap_id text NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.received_activity OWNER TO lemmy;

--
-- Name: received_activity_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.received_activity_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.received_activity_id_seq OWNER TO lemmy;

--
-- Name: received_activity_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.received_activity_id_seq OWNED BY public.received_activity.id;


--
-- Name: registration_application; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.registration_application (
    id integer NOT NULL,
    local_user_id integer NOT NULL,
    answer text NOT NULL,
    admin_id integer,
    deny_reason text,
    published timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.registration_application OWNER TO lemmy;

--
-- Name: registration_application_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.registration_application_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.registration_application_id_seq OWNER TO lemmy;

--
-- Name: registration_application_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.registration_application_id_seq OWNED BY public.registration_application.id;


--
-- Name: secret; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.secret (
    id integer NOT NULL,
    jwt_secret character varying DEFAULT gen_random_uuid() NOT NULL
);


ALTER TABLE public.secret OWNER TO lemmy;

--
-- Name: secret_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.secret_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.secret_id_seq OWNER TO lemmy;

--
-- Name: secret_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.secret_id_seq OWNED BY public.secret.id;


--
-- Name: sent_activity; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.sent_activity (
    id bigint NOT NULL,
    ap_id text NOT NULL,
    data json NOT NULL,
    sensitive boolean NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    send_inboxes text[] NOT NULL,
    send_community_followers_of integer,
    send_all_instances boolean NOT NULL,
    actor_type public.actor_type_enum NOT NULL,
    actor_apub_id text
);


ALTER TABLE public.sent_activity OWNER TO lemmy;

--
-- Name: sent_activity_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.sent_activity_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.sent_activity_id_seq OWNER TO lemmy;

--
-- Name: sent_activity_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.sent_activity_id_seq OWNED BY public.sent_activity.id;


--
-- Name: site; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.site (
    id integer NOT NULL,
    name character varying(20) NOT NULL,
    sidebar text,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone,
    icon text,
    banner text,
    description character varying(150),
    actor_id character varying(255) DEFAULT public.generate_unique_changeme() NOT NULL,
    last_refreshed_at timestamp with time zone DEFAULT now() NOT NULL,
    inbox_url character varying(255) DEFAULT public.generate_unique_changeme() NOT NULL,
    private_key text,
    public_key text DEFAULT public.generate_unique_changeme() NOT NULL,
    instance_id integer NOT NULL
);


ALTER TABLE public.site OWNER TO lemmy;

--
-- Name: site_aggregates; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.site_aggregates (
    id integer NOT NULL,
    site_id integer NOT NULL,
    users bigint DEFAULT 1 NOT NULL,
    posts bigint DEFAULT 0 NOT NULL,
    comments bigint DEFAULT 0 NOT NULL,
    communities bigint DEFAULT 0 NOT NULL,
    users_active_day bigint DEFAULT 0 NOT NULL,
    users_active_week bigint DEFAULT 0 NOT NULL,
    users_active_month bigint DEFAULT 0 NOT NULL,
    users_active_half_year bigint DEFAULT 0 NOT NULL
);


ALTER TABLE public.site_aggregates OWNER TO lemmy;

--
-- Name: site_aggregates_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.site_aggregates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.site_aggregates_id_seq OWNER TO lemmy;

--
-- Name: site_aggregates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.site_aggregates_id_seq OWNED BY public.site_aggregates.id;


--
-- Name: site_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.site_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.site_id_seq OWNER TO lemmy;

--
-- Name: site_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.site_id_seq OWNED BY public.site.id;


--
-- Name: site_language; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.site_language (
    id integer NOT NULL,
    site_id integer NOT NULL,
    language_id integer NOT NULL
);


ALTER TABLE public.site_language OWNER TO lemmy;

--
-- Name: site_language_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.site_language_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.site_language_id_seq OWNER TO lemmy;

--
-- Name: site_language_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.site_language_id_seq OWNED BY public.site_language.id;


--
-- Name: tagline; Type: TABLE; Schema: public; Owner: lemmy
--

CREATE TABLE public.tagline (
    id integer NOT NULL,
    local_site_id integer NOT NULL,
    content text NOT NULL,
    published timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone
);


ALTER TABLE public.tagline OWNER TO lemmy;

--
-- Name: tagline_id_seq; Type: SEQUENCE; Schema: public; Owner: lemmy
--

CREATE SEQUENCE public.tagline_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.tagline_id_seq OWNER TO lemmy;

--
-- Name: tagline_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: lemmy
--

ALTER SEQUENCE public.tagline_id_seq OWNED BY public.tagline.id;


--
-- Name: deps_saved_ddl; Type: TABLE; Schema: utils; Owner: lemmy
--

CREATE TABLE utils.deps_saved_ddl (
    id integer NOT NULL,
    view_schema character varying(255),
    view_name character varying(255),
    ddl_to_run text
);


ALTER TABLE utils.deps_saved_ddl OWNER TO lemmy;

--
-- Name: deps_saved_ddl_id_seq; Type: SEQUENCE; Schema: utils; Owner: lemmy
--

CREATE SEQUENCE utils.deps_saved_ddl_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE utils.deps_saved_ddl_id_seq OWNER TO lemmy;

--
-- Name: deps_saved_ddl_id_seq; Type: SEQUENCE OWNED BY; Schema: utils; Owner: lemmy
--

ALTER SEQUENCE utils.deps_saved_ddl_id_seq OWNED BY utils.deps_saved_ddl.id;


--
-- Name: admin_purge_comment id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_comment ALTER COLUMN id SET DEFAULT nextval('public.admin_purge_comment_id_seq'::regclass);


--
-- Name: admin_purge_community id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_community ALTER COLUMN id SET DEFAULT nextval('public.admin_purge_community_id_seq'::regclass);


--
-- Name: admin_purge_person id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_person ALTER COLUMN id SET DEFAULT nextval('public.admin_purge_person_id_seq'::regclass);


--
-- Name: admin_purge_post id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_post ALTER COLUMN id SET DEFAULT nextval('public.admin_purge_post_id_seq'::regclass);


--
-- Name: captcha_answer id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.captcha_answer ALTER COLUMN id SET DEFAULT nextval('public.captcha_answer_id_seq'::regclass);


--
-- Name: comment id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment ALTER COLUMN id SET DEFAULT nextval('public.comment_id_seq'::regclass);


--
-- Name: comment_aggregates id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_aggregates ALTER COLUMN id SET DEFAULT nextval('public.comment_aggregates_id_seq'::regclass);


--
-- Name: comment_like id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_like ALTER COLUMN id SET DEFAULT nextval('public.comment_like_id_seq'::regclass);


--
-- Name: comment_reply id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_reply ALTER COLUMN id SET DEFAULT nextval('public.comment_reply_id_seq'::regclass);


--
-- Name: comment_report id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_report ALTER COLUMN id SET DEFAULT nextval('public.comment_report_id_seq'::regclass);


--
-- Name: comment_saved id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_saved ALTER COLUMN id SET DEFAULT nextval('public.comment_saved_id_seq'::regclass);


--
-- Name: community id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community ALTER COLUMN id SET DEFAULT nextval('public.community_id_seq'::regclass);


--
-- Name: community_aggregates id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_aggregates ALTER COLUMN id SET DEFAULT nextval('public.community_aggregates_id_seq'::regclass);


--
-- Name: community_block id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_block ALTER COLUMN id SET DEFAULT nextval('public.community_block_id_seq'::regclass);


--
-- Name: community_follower id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_follower ALTER COLUMN id SET DEFAULT nextval('public.community_follower_id_seq'::regclass);


--
-- Name: community_language id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_language ALTER COLUMN id SET DEFAULT nextval('public.community_language_id_seq'::regclass);


--
-- Name: community_moderator id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_moderator ALTER COLUMN id SET DEFAULT nextval('public.community_moderator_id_seq'::regclass);


--
-- Name: community_person_ban id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_person_ban ALTER COLUMN id SET DEFAULT nextval('public.community_person_ban_id_seq'::regclass);


--
-- Name: custom_emoji id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.custom_emoji ALTER COLUMN id SET DEFAULT nextval('public.custom_emoji_id_seq'::regclass);


--
-- Name: custom_emoji_keyword id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.custom_emoji_keyword ALTER COLUMN id SET DEFAULT nextval('public.custom_emoji_keyword_id_seq'::regclass);


--
-- Name: email_verification id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.email_verification ALTER COLUMN id SET DEFAULT nextval('public.email_verification_id_seq'::regclass);


--
-- Name: federation_allowlist id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_allowlist ALTER COLUMN id SET DEFAULT nextval('public.federation_allowlist_id_seq'::regclass);


--
-- Name: federation_blocklist id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_blocklist ALTER COLUMN id SET DEFAULT nextval('public.federation_blocklist_id_seq'::regclass);


--
-- Name: federation_queue_state id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_queue_state ALTER COLUMN id SET DEFAULT nextval('public.federation_queue_state_id_seq'::regclass);


--
-- Name: image_upload id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.image_upload ALTER COLUMN id SET DEFAULT nextval('public.image_upload_id_seq'::regclass);


--
-- Name: instance id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.instance ALTER COLUMN id SET DEFAULT nextval('public.instance_id_seq'::regclass);


--
-- Name: language id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.language ALTER COLUMN id SET DEFAULT nextval('public.language_id_seq'::regclass);


--
-- Name: local_site id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_site ALTER COLUMN id SET DEFAULT nextval('public.local_site_id_seq'::regclass);


--
-- Name: local_site_rate_limit id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_site_rate_limit ALTER COLUMN id SET DEFAULT nextval('public.local_site_rate_limit_id_seq'::regclass);


--
-- Name: local_user id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_user ALTER COLUMN id SET DEFAULT nextval('public.local_user_id_seq'::regclass);


--
-- Name: local_user_language id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_user_language ALTER COLUMN id SET DEFAULT nextval('public.local_user_language_id_seq'::regclass);


--
-- Name: mod_add id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_add ALTER COLUMN id SET DEFAULT nextval('public.mod_add_id_seq'::regclass);


--
-- Name: mod_add_community id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_add_community ALTER COLUMN id SET DEFAULT nextval('public.mod_add_community_id_seq'::regclass);


--
-- Name: mod_ban id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_ban ALTER COLUMN id SET DEFAULT nextval('public.mod_ban_id_seq'::regclass);


--
-- Name: mod_ban_from_community id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_ban_from_community ALTER COLUMN id SET DEFAULT nextval('public.mod_ban_from_community_id_seq'::regclass);


--
-- Name: mod_feature_post id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_feature_post ALTER COLUMN id SET DEFAULT nextval('public.mod_sticky_post_id_seq'::regclass);


--
-- Name: mod_hide_community id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_hide_community ALTER COLUMN id SET DEFAULT nextval('public.mod_hide_community_id_seq'::regclass);


--
-- Name: mod_lock_post id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_lock_post ALTER COLUMN id SET DEFAULT nextval('public.mod_lock_post_id_seq'::regclass);


--
-- Name: mod_remove_comment id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_comment ALTER COLUMN id SET DEFAULT nextval('public.mod_remove_comment_id_seq'::regclass);


--
-- Name: mod_remove_community id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_community ALTER COLUMN id SET DEFAULT nextval('public.mod_remove_community_id_seq'::regclass);


--
-- Name: mod_remove_post id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_post ALTER COLUMN id SET DEFAULT nextval('public.mod_remove_post_id_seq'::regclass);


--
-- Name: mod_transfer_community id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_transfer_community ALTER COLUMN id SET DEFAULT nextval('public.mod_transfer_community_id_seq'::regclass);


--
-- Name: password_reset_request id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.password_reset_request ALTER COLUMN id SET DEFAULT nextval('public.password_reset_request_id_seq'::regclass);


--
-- Name: person id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person ALTER COLUMN id SET DEFAULT nextval('public.person_id_seq'::regclass);


--
-- Name: person_aggregates id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_aggregates ALTER COLUMN id SET DEFAULT nextval('public.person_aggregates_id_seq'::regclass);


--
-- Name: person_ban id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_ban ALTER COLUMN id SET DEFAULT nextval('public.person_ban_id_seq'::regclass);


--
-- Name: person_block id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_block ALTER COLUMN id SET DEFAULT nextval('public.person_block_id_seq'::regclass);


--
-- Name: person_follower id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_follower ALTER COLUMN id SET DEFAULT nextval('public.person_follower_id_seq'::regclass);


--
-- Name: person_mention id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_mention ALTER COLUMN id SET DEFAULT nextval('public.person_mention_id_seq'::regclass);


--
-- Name: person_post_aggregates id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_post_aggregates ALTER COLUMN id SET DEFAULT nextval('public.person_post_aggregates_id_seq'::regclass);


--
-- Name: post id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post ALTER COLUMN id SET DEFAULT nextval('public.post_id_seq'::regclass);


--
-- Name: post_aggregates id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_aggregates ALTER COLUMN id SET DEFAULT nextval('public.post_aggregates_id_seq'::regclass);


--
-- Name: post_like id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_like ALTER COLUMN id SET DEFAULT nextval('public.post_like_id_seq'::regclass);


--
-- Name: post_read id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_read ALTER COLUMN id SET DEFAULT nextval('public.post_read_id_seq'::regclass);


--
-- Name: post_report id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_report ALTER COLUMN id SET DEFAULT nextval('public.post_report_id_seq'::regclass);


--
-- Name: post_saved id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_saved ALTER COLUMN id SET DEFAULT nextval('public.post_saved_id_seq'::regclass);


--
-- Name: private_message id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message ALTER COLUMN id SET DEFAULT nextval('public.private_message_id_seq'::regclass);


--
-- Name: private_message_report id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message_report ALTER COLUMN id SET DEFAULT nextval('public.private_message_report_id_seq'::regclass);


--
-- Name: received_activity id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.received_activity ALTER COLUMN id SET DEFAULT nextval('public.received_activity_id_seq'::regclass);


--
-- Name: registration_application id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.registration_application ALTER COLUMN id SET DEFAULT nextval('public.registration_application_id_seq'::regclass);


--
-- Name: secret id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.secret ALTER COLUMN id SET DEFAULT nextval('public.secret_id_seq'::regclass);


--
-- Name: sent_activity id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.sent_activity ALTER COLUMN id SET DEFAULT nextval('public.sent_activity_id_seq'::regclass);


--
-- Name: site id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site ALTER COLUMN id SET DEFAULT nextval('public.site_id_seq'::regclass);


--
-- Name: site_aggregates id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site_aggregates ALTER COLUMN id SET DEFAULT nextval('public.site_aggregates_id_seq'::regclass);


--
-- Name: site_language id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site_language ALTER COLUMN id SET DEFAULT nextval('public.site_language_id_seq'::regclass);


--
-- Name: tagline id; Type: DEFAULT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.tagline ALTER COLUMN id SET DEFAULT nextval('public.tagline_id_seq'::regclass);


--
-- Name: deps_saved_ddl id; Type: DEFAULT; Schema: utils; Owner: lemmy
--

ALTER TABLE ONLY utils.deps_saved_ddl ALTER COLUMN id SET DEFAULT nextval('utils.deps_saved_ddl_id_seq'::regclass);


--
-- Data for Name: __diesel_schema_migrations; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.__diesel_schema_migrations (version, run_on) FROM stdin;
00000000000000	2023-09-16 23:25:40.476901
20190226002946	2023-09-16 23:25:40.479358
20190227170003	2023-09-16 23:25:40.495726
20190303163336	2023-09-16 23:25:40.532981
20190305233828	2023-09-16 23:25:40.555649
20190330212058	2023-09-16 23:25:40.572882
20190403155205	2023-09-16 23:25:40.57714
20190403155309	2023-09-16 23:25:40.581805
20190407003142	2023-09-16 23:25:40.588867
20190408015947	2023-09-16 23:25:40.632514
20190411144915	2023-09-16 23:25:40.634624
20190429175834	2023-09-16 23:25:40.640734
20190502051656	2023-09-16 23:25:40.650381
20190601222649	2023-09-16 23:25:40.653627
20190811000918	2023-09-16 23:25:40.657436
20190829040006	2023-09-16 23:25:40.66388
20190905230317	2023-09-16 23:25:40.666015
20190909042010	2023-09-16 23:25:40.672824
20191015181630	2023-09-16 23:25:40.682125
20191019052737	2023-09-16 23:25:40.683453
20191021011237	2023-09-16 23:25:40.690969
20191024002614	2023-09-16 23:25:40.692559
20191209060754	2023-09-16 23:25:40.698989
20191211181820	2023-09-16 23:25:40.703132
20191229164820	2023-09-16 23:25:40.705732
20200101200418	2023-09-16 23:25:40.733271
20200102172755	2023-09-16 23:25:40.735646
20200111012452	2023-09-16 23:25:40.738329
20200113025151	2023-09-16 23:25:40.763793
20200121001001	2023-09-16 23:25:40.81005
20200129011901	2023-09-16 23:25:40.834714
20200129030825	2023-09-16 23:25:40.837567
20200202004806	2023-09-16 23:25:40.840707
20200206165953	2023-09-16 23:25:40.86472
20200207210055	2023-09-16 23:25:40.88347
20200208145624	2023-09-16 23:25:40.901299
20200306202329	2023-09-16 23:25:40.937576
20200326192410	2023-09-16 23:25:40.95809
20200403194936	2023-09-16 23:25:40.968081
20200407135912	2023-09-16 23:25:40.969891
20200414163701	2023-09-16 23:25:40.979836
20200421123957	2023-09-16 23:25:41.057878
20200505210233	2023-09-16 23:25:41.061533
20200630135809	2023-09-16 23:25:41.069647
20200708202609	2023-09-16 23:25:41.131538
20200712100442	2023-09-16 23:25:41.168837
20200718234519	2023-09-16 23:25:41.187683
20200803000110	2023-09-16 23:25:41.194572
20200806205355	2023-09-16 23:25:41.256737
20200825132005	2023-09-16 23:25:41.270036
20200907231141	2023-09-16 23:25:41.282652
20201007234221	2023-09-16 23:25:41.289104
20201010035723	2023-09-16 23:25:41.290805
20201013212240	2023-09-16 23:25:41.292244
20201023115011	2023-09-16 23:25:41.311401
20201105152724	2023-09-16 23:25:41.312634
20201110150835	2023-09-16 23:25:41.314086
20201126134531	2023-09-16 23:25:41.315247
20201202152437	2023-09-16 23:25:41.316609
20201203035643	2023-09-16 23:25:41.32279
20201204183345	2023-09-16 23:25:41.333265
20201210152350	2023-09-16 23:25:41.340951
20201214020038	2023-09-16 23:25:41.34861
20201217030456	2023-09-16 23:25:41.355711
20201217031053	2023-09-16 23:25:41.359141
20210105200932	2023-09-16 23:25:41.371115
20210126173850	2023-09-16 23:25:41.408151
20210127202728	2023-09-16 23:25:41.40941
20210131050334	2023-09-16 23:25:41.413234
20210202153240	2023-09-16 23:25:41.419071
20210210164051	2023-09-16 23:25:41.483051
20210213210612	2023-09-16 23:25:41.494176
20210225112959	2023-09-16 23:25:41.495557
20210228162616	2023-09-16 23:25:41.497518
20210304040229	2023-09-16 23:25:41.498619
20210309171136	2023-09-16 23:25:41.500269
20210319014144	2023-09-16 23:25:41.534852
20210320185321	2023-09-16 23:25:41.536221
20210331103917	2023-09-16 23:25:41.540022
20210331105915	2023-09-16 23:25:41.541312
20210331144349	2023-09-16 23:25:41.544999
20210401173552	2023-09-16 23:25:41.549058
20210401181826	2023-09-16 23:25:41.552212
20210402021422	2023-09-16 23:25:41.555785
20210420155001	2023-09-16 23:25:41.557434
20210424174047	2023-09-16 23:25:41.558692
20210719130929	2023-09-16 23:25:41.559873
20210720102033	2023-09-16 23:25:41.561154
20210802002342	2023-09-16 23:25:41.564571
20210804223559	2023-09-16 23:25:41.566052
20210816004209	2023-09-16 23:25:41.577873
20210817210508	2023-09-16 23:25:41.579249
20210920112945	2023-09-16 23:25:41.584082
20211001141650	2023-09-16 23:25:41.593225
20211122135324	2023-09-16 23:25:41.614986
20211122143904	2023-09-16 23:25:41.618609
20211123031528	2023-09-16 23:25:41.622945
20211123132840	2023-09-16 23:25:41.628288
20211123153753	2023-09-16 23:25:41.63506
20211209225529	2023-09-16 23:25:41.646701
20211214181537	2023-09-16 23:25:41.648121
20220104034553	2023-09-16 23:25:41.652572
20220120160328	2023-09-16 23:25:41.660833
20220128104106	2023-09-16 23:25:41.662399
20220201154240	2023-09-16 23:25:41.67368
20220218210946	2023-09-16 23:25:41.677165
20220404183652	2023-09-16 23:25:41.678457
20220411210137	2023-09-16 23:25:41.683429
20220412114352	2023-09-16 23:25:41.684549
20220412185205	2023-09-16 23:25:41.685751
20220419111004	2023-09-16 23:25:41.686971
20220426105145	2023-09-16 23:25:41.688326
20220519153931	2023-09-16 23:25:41.689592
20220520135341	2023-09-16 23:25:41.690695
20220612012121	2023-09-16 23:25:41.691902
20220613124806	2023-09-16 23:25:41.693089
20220621123144	2023-09-16 23:25:41.69419
20220707182650	2023-09-16 23:25:41.712073
20220804150644	2023-09-16 23:25:41.753068
20220804214722	2023-09-16 23:25:41.754599
20220805203502	2023-09-16 23:25:41.755868
20220822193848	2023-09-16 23:25:41.762998
20220907113813	2023-09-16 23:25:41.765412
20220907114618	2023-09-16 23:25:41.766728
20220908102358	2023-09-16 23:25:41.776104
20220924161829	2023-09-16 23:25:41.788229
20221006183632	2023-09-16 23:25:41.789916
20221113181529	2023-09-16 23:25:41.827599
20221120032430	2023-09-16 23:25:41.834231
20221121143249	2023-09-16 23:25:41.841863
20221121204256	2023-09-16 23:25:41.843728
20221205110642	2023-09-16 23:25:41.853041
20230117165819	2023-09-16 23:25:41.856103
20230201012747	2023-09-16 23:25:41.890479
20230205102549	2023-09-16 23:25:41.897442
20230207030958	2023-09-16 23:25:41.899065
20230211173347	2023-09-16 23:25:41.90608
20230213172528	2023-09-16 23:25:41.927174
20230213221303	2023-09-16 23:25:41.928887
20230215212546	2023-09-16 23:25:41.933167
20230216194139	2023-09-16 23:25:41.941759
20230414175955	2023-09-16 23:25:41.943395
20230423164732	2023-09-16 23:25:41.986299
20230510095739	2023-09-16 23:25:42.036025
20230606104440	2023-09-16 23:25:42.037596
20230607105918	2023-09-16 23:25:42.056007
20230617175955	2023-09-16 23:25:42.0847
20230619055530	2023-09-16 23:25:42.085992
20230619120700	2023-09-16 23:25:42.087348
20230620191145	2023-09-16 23:25:42.090784
20230621153242	2023-09-16 23:25:42.091984
20230622051755	2023-09-16 23:25:42.101099
20230622101245	2023-09-16 23:25:42.103009
20230624072904	2023-09-16 23:25:42.104631
20230624185942	2023-09-16 23:25:42.105995
20230627065106	2023-09-16 23:25:42.111559
20230704153335	2023-09-16 23:25:42.113319
20230705000058	2023-09-16 23:25:42.148601
20230706151124	2023-09-16 23:25:42.152684
20230708101154	2023-09-16 23:25:42.154016
20230710075550	2023-09-16 23:25:42.156044
20230711084714	2023-09-16 23:25:42.157586
20230714154840	2023-09-16 23:25:42.175436
20230714215339	2023-09-16 23:25:42.201824
20230718082614	2023-09-16 23:25:42.209652
20230719163511	2023-09-16 23:25:42.212898
20230724232635	2023-09-16 23:25:42.218519
20230726000217	2023-09-16 23:25:42.227357
20230726222023	2023-09-16 23:25:42.236355
20230727134652	2023-09-16 23:25:42.237756
20230801101826	2023-09-16 23:25:42.239197
20230801115243	2023-09-16 23:25:42.241289
20230802144930	2023-09-16 23:25:42.250346
20230802174444	2023-09-16 23:25:42.251486
20230808163911	2023-09-16 23:25:42.345627
20230823182533	2023-09-16 23:25:42.347368
20230829183053	2023-09-16 23:25:42.437526
20230831205559	2023-09-16 23:25:42.438838
20230901112158	2023-09-16 23:25:42.452688
20230916230213	2023-09-16 23:27:04.845064
20230916232908	2023-09-16 23:30:28.559355
\.


--
-- Data for Name: admin_purge_comment; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.admin_purge_comment (id, admin_person_id, post_id, reason, when_) FROM stdin;
\.


--
-- Data for Name: admin_purge_community; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.admin_purge_community (id, admin_person_id, reason, when_) FROM stdin;
\.


--
-- Data for Name: admin_purge_person; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.admin_purge_person (id, admin_person_id, reason, when_) FROM stdin;
\.


--
-- Data for Name: admin_purge_post; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.admin_purge_post (id, admin_person_id, community_id, reason, when_) FROM stdin;
\.


--
-- Data for Name: captcha_answer; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.captcha_answer (id, uuid, answer, published) FROM stdin;
\.


--
-- Data for Name: comment; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.comment (id, creator_id, post_id, content, removed, published, updated, deleted, ap_id, local, path, distinguished, language_id, bid) FROM stdin;
\.


--
-- Data for Name: comment_aggregates; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.comment_aggregates (id, comment_id, score, upvotes, downvotes, published, child_count, hot_rank, controversy_rank) FROM stdin;
\.


--
-- Data for Name: comment_like; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.comment_like (id, person_id, comment_id, post_id, score, published) FROM stdin;
\.


--
-- Data for Name: comment_reply; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.comment_reply (id, recipient_id, comment_id, read, published) FROM stdin;
\.


--
-- Data for Name: comment_report; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.comment_report (id, creator_id, comment_id, original_comment_text, reason, resolved, resolver_id, published, updated) FROM stdin;
\.


--
-- Data for Name: comment_saved; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.comment_saved (id, comment_id, person_id, published) FROM stdin;
\.


--
-- Data for Name: community; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.community (id, name, title, description, removed, published, updated, deleted, nsfw, actor_id, local, private_key, public_key, last_refreshed_at, icon, banner, followers_url, inbox_url, shared_inbox_url, hidden, posting_restricted_to_mods, instance_id, moderators_url, featured_url) FROM stdin;
\.


--
-- Data for Name: community_aggregates; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.community_aggregates (id, community_id, subscribers, posts, comments, published, users_active_day, users_active_week, users_active_month, users_active_half_year, hot_rank) FROM stdin;
\.


--
-- Data for Name: community_block; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.community_block (id, person_id, community_id, published) FROM stdin;
\.


--
-- Data for Name: community_follower; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.community_follower (id, community_id, person_id, published, pending) FROM stdin;
\.


--
-- Data for Name: community_language; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.community_language (id, community_id, language_id) FROM stdin;
\.


--
-- Data for Name: community_moderator; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.community_moderator (id, community_id, person_id, published) FROM stdin;
\.


--
-- Data for Name: community_person_ban; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.community_person_ban (id, community_id, person_id, published, expires) FROM stdin;
\.


--
-- Data for Name: custom_emoji; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.custom_emoji (id, local_site_id, shortcode, image_url, alt_text, category, published, updated) FROM stdin;
\.


--
-- Data for Name: custom_emoji_keyword; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.custom_emoji_keyword (id, custom_emoji_id, keyword) FROM stdin;
\.


--
-- Data for Name: email_verification; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.email_verification (id, local_user_id, email, verification_token, published) FROM stdin;
\.


--
-- Data for Name: federation_allowlist; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.federation_allowlist (id, instance_id, published, updated) FROM stdin;
\.


--
-- Data for Name: federation_blocklist; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.federation_blocklist (id, instance_id, published, updated) FROM stdin;
\.


--
-- Data for Name: federation_queue_state; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.federation_queue_state (id, instance_id, last_successful_id, fail_count, last_retry) FROM stdin;
\.


--
-- Data for Name: image_upload; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.image_upload (id, local_user_id, pictrs_alias, pictrs_delete_token, published) FROM stdin;
\.


--
-- Data for Name: instance; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.instance (id, domain, published, updated, software, version) FROM stdin;
\.


--
-- Data for Name: language; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.language (id, code, name) FROM stdin;
0	und	Undetermined
1	aa	Afaraf
2	ab	аҧсуа бызшәа
3	ae	avesta
4	af	Afrikaans
5	ak	Akan
6	am	አማርኛ
7	an	aragonés
8	ar	اَلْعَرَبِيَّةُ
9	as	অসমীয়া
10	av	авар мацӀ
11	ay	aymar aru
12	az	azərbaycan dili
13	ba	башҡорт теле
14	be	беларуская мова
15	bg	български език
16	bi	Bislama
17	bm	bamanankan
18	bn	বাংলা
19	bo	བོད་ཡིག
20	br	brezhoneg
21	bs	bosanski jezik
22	ca	Català
23	ce	нохчийн мотт
24	ch	Chamoru
25	co	corsu
26	cr	ᓀᐦᐃᔭᐍᐏᐣ
27	cs	čeština
28	cu	ѩзыкъ словѣньскъ
29	cv	чӑваш чӗлхи
30	cy	Cymraeg
31	da	dansk
32	de	Deutsch
33	dv	ދިވެހި
34	dz	རྫོང་ཁ
35	ee	Eʋegbe
36	el	Ελληνικά
37	en	English
38	eo	Esperanto
39	es	Español
40	et	eesti
41	eu	euskara
42	fa	فارسی
43	ff	Fulfulde
44	fi	suomi
45	fj	vosa Vakaviti
46	fo	føroyskt
47	fr	Français
48	fy	Frysk
49	ga	Gaeilge
50	gd	Gàidhlig
51	gl	galego
52	gn	Avañe'ẽ
53	gu	ગુજરાતી
54	gv	Gaelg
55	ha	هَوُسَ
56	he	עברית
57	hi	हिन्दी
58	ho	Hiri Motu
59	hr	Hrvatski
60	ht	Kreyòl ayisyen
61	hu	magyar
62	hy	Հայերեն
63	hz	Otjiherero
64	ia	Interlingua
65	id	Bahasa Indonesia
66	ie	Interlingue
67	ig	Asụsụ Igbo
68	ii	ꆈꌠ꒿ Nuosuhxop
69	ik	Iñupiaq
70	io	Ido
71	is	Íslenska
72	it	Italiano
73	iu	ᐃᓄᒃᑎᑐᑦ
74	ja	日本語
75	jv	basa Jawa
76	ka	ქართული
77	kg	Kikongo
78	ki	Gĩkũyũ
79	kj	Kuanyama
80	kk	қазақ тілі
81	kl	kalaallisut
82	km	ខេមរភាសា
83	kn	ಕನ್ನಡ
84	ko	한국어
85	kr	Kanuri
86	ks	कश्मीरी
87	ku	Kurdî
88	kv	коми кыв
89	kw	Kernewek
90	ky	Кыргызча
91	la	latine
92	lb	Lëtzebuergesch
93	lg	Luganda
94	li	Limburgs
95	ln	Lingála
96	lo	ພາສາລາວ
97	lt	lietuvių kalba
98	lu	Kiluba
99	lv	latviešu valoda
100	mg	fiteny malagasy
101	mh	Kajin M̧ajeļ
102	mi	te reo Māori
103	mk	македонски јазик
104	ml	മലയാളം
105	mn	Монгол хэл
106	mr	मराठी
107	ms	Bahasa Melayu
108	mt	Malti
109	my	ဗမာစာ
110	na	Dorerin Naoero
111	nb	Norsk bokmål
112	nd	isiNdebele
113	ne	नेपाली
114	ng	Owambo
115	nl	Nederlands
116	nn	Norsk nynorsk
117	no	Norsk
118	nr	isiNdebele
119	nv	Diné bizaad
120	ny	chiCheŵa
121	oc	occitan
122	oj	ᐊᓂᔑᓈᐯᒧᐎᓐ
123	om	Afaan Oromoo
124	or	ଓଡ଼ିଆ
125	os	ирон æвзаг
126	pa	ਪੰਜਾਬੀ
127	pi	पाऴि
128	pl	Polski
129	ps	پښتو
130	pt	Português
131	qu	Runa Simi
132	rm	rumantsch grischun
133	rn	Ikirundi
134	ro	Română
135	ru	Русский
136	rw	Ikinyarwanda
137	sa	संस्कृतम्
138	sc	sardu
139	sd	सिन्धी
140	se	Davvisámegiella
141	sg	yângâ tî sängö
142	si	සිංහල
143	sk	slovenčina
144	sl	slovenščina
145	sm	gagana fa'a Samoa
146	sn	chiShona
147	so	Soomaaliga
148	sq	Shqip
149	sr	српски језик
150	ss	SiSwati
151	st	Sesotho
152	su	Basa Sunda
153	sv	Svenska
154	sw	Kiswahili
155	ta	தமிழ்
156	te	తెలుగు
157	tg	тоҷикӣ
158	th	ไทย
159	ti	ትግርኛ
160	tk	Türkmençe
161	tl	Wikang Tagalog
162	tn	Setswana
163	to	faka Tonga
164	tr	Türkçe
165	ts	Xitsonga
166	tt	татар теле
167	tw	Twi
168	ty	Reo Tahiti
169	ug	ئۇيغۇرچە‎
170	uk	Українська
171	ur	اردو
172	uz	Ўзбек
173	ve	Tshivenḓa
174	vi	Tiếng Việt
175	vo	Volapük
176	wa	walon
177	wo	Wollof
178	xh	isiXhosa
179	yi	ייִדיש
180	yo	Yorùbá
181	za	Saɯ cueŋƅ
182	zh	中文
183	zu	isiZulu
\.


--
-- Data for Name: local_site; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.local_site (id, site_id, site_setup, enable_downvotes, enable_nsfw, community_creation_admin_only, require_email_verification, application_question, private_instance, default_theme, default_post_listing_type, legal_information, hide_modlog_mod_names, application_email_admins, slur_filter_regex, actor_name_max_length, federation_enabled, captcha_enabled, captcha_difficulty, published, updated, registration_mode, reports_email_admins) FROM stdin;
\.


--
-- Data for Name: local_site_rate_limit; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.local_site_rate_limit (id, local_site_id, message, message_per_second, post, post_per_second, register, register_per_second, image, image_per_second, comment, comment_per_second, search, search_per_second, published, updated) FROM stdin;
\.


--
-- Data for Name: local_user; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.local_user (id, person_id, password_encrypted, email, show_nsfw, theme, default_sort_type, default_listing_type, interface_language, show_avatars, send_notifications_to_email, validator_time, show_scores, show_bot_accounts, show_read_posts, show_new_post_notifs, email_verified, accepted_application, totp_2fa_secret, totp_2fa_url, open_links_in_new_tab, blur_nsfw, auto_expand, infinite_scroll_enabled, admin, post_listing_mode) FROM stdin;
\.


--
-- Data for Name: local_user_language; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.local_user_language (id, local_user_id, language_id) FROM stdin;
\.


--
-- Data for Name: mod_add; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_add (id, mod_person_id, other_person_id, removed, when_) FROM stdin;
\.


--
-- Data for Name: mod_add_community; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_add_community (id, mod_person_id, other_person_id, community_id, removed, when_) FROM stdin;
\.


--
-- Data for Name: mod_ban; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_ban (id, mod_person_id, other_person_id, reason, banned, expires, when_) FROM stdin;
\.


--
-- Data for Name: mod_ban_from_community; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_ban_from_community (id, mod_person_id, other_person_id, community_id, reason, banned, expires, when_) FROM stdin;
\.


--
-- Data for Name: mod_feature_post; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_feature_post (id, mod_person_id, post_id, featured, when_, is_featured_community) FROM stdin;
\.


--
-- Data for Name: mod_hide_community; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_hide_community (id, community_id, mod_person_id, when_, reason, hidden) FROM stdin;
\.


--
-- Data for Name: mod_lock_post; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_lock_post (id, mod_person_id, post_id, locked, when_) FROM stdin;
\.


--
-- Data for Name: mod_remove_comment; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_remove_comment (id, mod_person_id, comment_id, reason, removed, when_) FROM stdin;
\.


--
-- Data for Name: mod_remove_community; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_remove_community (id, mod_person_id, community_id, reason, removed, expires, when_) FROM stdin;
\.


--
-- Data for Name: mod_remove_post; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_remove_post (id, mod_person_id, post_id, reason, removed, when_) FROM stdin;
\.


--
-- Data for Name: mod_transfer_community; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.mod_transfer_community (id, mod_person_id, other_person_id, community_id, when_) FROM stdin;
\.


--
-- Data for Name: password_reset_request; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.password_reset_request (id, token, published, local_user_id) FROM stdin;
\.


--
-- Data for Name: person; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.person (id, name, display_name, avatar, banned, published, updated, actor_id, bio, local, private_key, public_key, last_refreshed_at, banner, deleted, inbox_url, shared_inbox_url, matrix_user_id, bot_account, ban_expires, instance_id) FROM stdin;
\.


--
-- Data for Name: person_aggregates; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.person_aggregates (id, person_id, post_count, post_score, comment_count, comment_score) FROM stdin;
\.


--
-- Data for Name: person_ban; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.person_ban (id, person_id, published) FROM stdin;
\.


--
-- Data for Name: person_block; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.person_block (id, person_id, target_id, published) FROM stdin;
\.


--
-- Data for Name: person_follower; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.person_follower (id, person_id, follower_id, published, pending) FROM stdin;
\.


--
-- Data for Name: person_mention; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.person_mention (id, recipient_id, comment_id, read, published) FROM stdin;
\.


--
-- Data for Name: person_post_aggregates; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.person_post_aggregates (id, person_id, post_id, read_comments, published) FROM stdin;
\.


--
-- Data for Name: post; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.post (id, name, url, body, creator_id, community_id, removed, locked, published, updated, deleted, nsfw, embed_title, embed_description, thumbnail_url, ap_id, local, embed_video_url, language_id, featured_community, featured_local, pickup_location, pickup_time, pickup_contact, pickup_notes, dropoff_location, dropoff_time, dropoff_contact, dropoff_notes) FROM stdin;
\.


--
-- Data for Name: post_aggregates; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.post_aggregates (id, post_id, comments, score, upvotes, downvotes, published, newest_comment_time_necro, newest_comment_time, featured_community, featured_local, hot_rank, hot_rank_active, community_id, creator_id, controversy_rank, scaled_rank) FROM stdin;
\.


--
-- Data for Name: post_like; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.post_like (id, post_id, person_id, score, published) FROM stdin;
\.


--
-- Data for Name: post_read; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.post_read (id, post_id, person_id, published) FROM stdin;
\.


--
-- Data for Name: post_report; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.post_report (id, creator_id, post_id, original_post_name, original_post_url, original_post_body, reason, resolved, resolver_id, published, updated) FROM stdin;
\.


--
-- Data for Name: post_saved; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.post_saved (id, post_id, person_id, published) FROM stdin;
\.


--
-- Data for Name: private_message; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.private_message (id, creator_id, recipient_id, content, deleted, read, published, updated, ap_id, local) FROM stdin;
\.


--
-- Data for Name: private_message_report; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.private_message_report (id, creator_id, private_message_id, original_pm_text, reason, resolved, resolver_id, published, updated) FROM stdin;
\.


--
-- Data for Name: received_activity; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.received_activity (id, ap_id, published) FROM stdin;
\.


--
-- Data for Name: registration_application; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.registration_application (id, local_user_id, answer, admin_id, deny_reason, published) FROM stdin;
\.


--
-- Data for Name: secret; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.secret (id, jwt_secret) FROM stdin;
1	ca3443c9-fe90-45d2-803e-eea949f62ce1
\.


--
-- Data for Name: sent_activity; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.sent_activity (id, ap_id, data, sensitive, published, send_inboxes, send_community_followers_of, send_all_instances, actor_type, actor_apub_id) FROM stdin;
\.


--
-- Data for Name: site; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.site (id, name, sidebar, published, updated, icon, banner, description, actor_id, last_refreshed_at, inbox_url, private_key, public_key, instance_id) FROM stdin;
\.


--
-- Data for Name: site_aggregates; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.site_aggregates (id, site_id, users, posts, comments, communities, users_active_day, users_active_week, users_active_month, users_active_half_year) FROM stdin;
\.


--
-- Data for Name: site_language; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.site_language (id, site_id, language_id) FROM stdin;
\.


--
-- Data for Name: tagline; Type: TABLE DATA; Schema: public; Owner: lemmy
--

COPY public.tagline (id, local_site_id, content, published, updated) FROM stdin;
\.


--
-- Data for Name: deps_saved_ddl; Type: TABLE DATA; Schema: utils; Owner: lemmy
--

COPY utils.deps_saved_ddl (id, view_schema, view_name, ddl_to_run) FROM stdin;
\.


--
-- Name: admin_purge_comment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.admin_purge_comment_id_seq', 1, false);


--
-- Name: admin_purge_community_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.admin_purge_community_id_seq', 1, false);


--
-- Name: admin_purge_person_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.admin_purge_person_id_seq', 1, false);


--
-- Name: admin_purge_post_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.admin_purge_post_id_seq', 1, false);


--
-- Name: captcha_answer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.captcha_answer_id_seq', 1, false);


--
-- Name: comment_aggregates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.comment_aggregates_id_seq', 1, false);


--
-- Name: comment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.comment_id_seq', 1, false);


--
-- Name: comment_like_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.comment_like_id_seq', 1, false);


--
-- Name: comment_reply_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.comment_reply_id_seq', 1, false);


--
-- Name: comment_report_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.comment_report_id_seq', 1, false);


--
-- Name: comment_saved_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.comment_saved_id_seq', 1, false);


--
-- Name: community_aggregates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.community_aggregates_id_seq', 1, false);


--
-- Name: community_block_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.community_block_id_seq', 1, false);


--
-- Name: community_follower_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.community_follower_id_seq', 1, false);


--
-- Name: community_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.community_id_seq', 1, true);


--
-- Name: community_language_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.community_language_id_seq', 1, false);


--
-- Name: community_moderator_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.community_moderator_id_seq', 1, false);


--
-- Name: community_person_ban_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.community_person_ban_id_seq', 1, false);


--
-- Name: custom_emoji_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.custom_emoji_id_seq', 1, false);


--
-- Name: custom_emoji_keyword_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.custom_emoji_keyword_id_seq', 1, false);


--
-- Name: email_verification_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.email_verification_id_seq', 1, false);


--
-- Name: federation_allowlist_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.federation_allowlist_id_seq', 1, false);


--
-- Name: federation_blocklist_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.federation_blocklist_id_seq', 1, false);


--
-- Name: federation_queue_state_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.federation_queue_state_id_seq', 1, false);


--
-- Name: image_upload_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.image_upload_id_seq', 1, false);


--
-- Name: instance_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.instance_id_seq', 1, false);


--
-- Name: language_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.language_id_seq', 183, true);


--
-- Name: local_site_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.local_site_id_seq', 1, false);


--
-- Name: local_site_rate_limit_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.local_site_rate_limit_id_seq', 1, false);


--
-- Name: local_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.local_user_id_seq', 1, false);


--
-- Name: local_user_language_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.local_user_language_id_seq', 1, false);


--
-- Name: mod_add_community_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_add_community_id_seq', 1, false);


--
-- Name: mod_add_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_add_id_seq', 1, false);


--
-- Name: mod_ban_from_community_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_ban_from_community_id_seq', 1, false);


--
-- Name: mod_ban_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_ban_id_seq', 1, false);


--
-- Name: mod_hide_community_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_hide_community_id_seq', 1, false);


--
-- Name: mod_lock_post_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_lock_post_id_seq', 1, false);


--
-- Name: mod_remove_comment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_remove_comment_id_seq', 1, false);


--
-- Name: mod_remove_community_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_remove_community_id_seq', 1, false);


--
-- Name: mod_remove_post_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_remove_post_id_seq', 1, false);


--
-- Name: mod_sticky_post_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_sticky_post_id_seq', 1, false);


--
-- Name: mod_transfer_community_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.mod_transfer_community_id_seq', 1, false);


--
-- Name: password_reset_request_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.password_reset_request_id_seq', 1, false);


--
-- Name: person_aggregates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.person_aggregates_id_seq', 1, false);


--
-- Name: person_ban_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.person_ban_id_seq', 1, false);


--
-- Name: person_block_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.person_block_id_seq', 1, false);


--
-- Name: person_follower_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.person_follower_id_seq', 1, false);


--
-- Name: person_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.person_id_seq', 1, true);


--
-- Name: person_mention_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.person_mention_id_seq', 1, false);


--
-- Name: person_post_aggregates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.person_post_aggregates_id_seq', 1, false);


--
-- Name: post_aggregates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.post_aggregates_id_seq', 1, false);


--
-- Name: post_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.post_id_seq', 1, false);


--
-- Name: post_like_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.post_like_id_seq', 1, false);


--
-- Name: post_read_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.post_read_id_seq', 1, false);


--
-- Name: post_report_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.post_report_id_seq', 1, false);


--
-- Name: post_saved_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.post_saved_id_seq', 1, false);


--
-- Name: private_message_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.private_message_id_seq', 1, false);


--
-- Name: private_message_report_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.private_message_report_id_seq', 1, false);


--
-- Name: received_activity_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.received_activity_id_seq', 1, false);


--
-- Name: registration_application_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.registration_application_id_seq', 1, false);


--
-- Name: secret_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.secret_id_seq', 1, true);


--
-- Name: sent_activity_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.sent_activity_id_seq', 1, false);


--
-- Name: site_aggregates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.site_aggregates_id_seq', 1, false);


--
-- Name: site_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.site_id_seq', 1, false);


--
-- Name: site_language_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.site_language_id_seq', 1, false);


--
-- Name: tagline_id_seq; Type: SEQUENCE SET; Schema: public; Owner: lemmy
--

SELECT pg_catalog.setval('public.tagline_id_seq', 1, false);


--
-- Name: deps_saved_ddl_id_seq; Type: SEQUENCE SET; Schema: utils; Owner: lemmy
--

SELECT pg_catalog.setval('utils.deps_saved_ddl_id_seq', 1, false);


--
-- Name: __diesel_schema_migrations __diesel_schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.__diesel_schema_migrations
    ADD CONSTRAINT __diesel_schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: admin_purge_comment admin_purge_comment_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_comment
    ADD CONSTRAINT admin_purge_comment_pkey PRIMARY KEY (id);


--
-- Name: admin_purge_community admin_purge_community_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_community
    ADD CONSTRAINT admin_purge_community_pkey PRIMARY KEY (id);


--
-- Name: admin_purge_person admin_purge_person_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_person
    ADD CONSTRAINT admin_purge_person_pkey PRIMARY KEY (id);


--
-- Name: admin_purge_post admin_purge_post_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_post
    ADD CONSTRAINT admin_purge_post_pkey PRIMARY KEY (id);


--
-- Name: captcha_answer captcha_answer_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.captcha_answer
    ADD CONSTRAINT captcha_answer_pkey PRIMARY KEY (id);


--
-- Name: captcha_answer captcha_answer_uuid_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.captcha_answer
    ADD CONSTRAINT captcha_answer_uuid_key UNIQUE (uuid);


--
-- Name: comment_aggregates comment_aggregates_comment_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_aggregates
    ADD CONSTRAINT comment_aggregates_comment_id_key UNIQUE (comment_id);


--
-- Name: comment_aggregates comment_aggregates_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_aggregates
    ADD CONSTRAINT comment_aggregates_pkey PRIMARY KEY (id);


--
-- Name: comment_like comment_like_comment_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_like
    ADD CONSTRAINT comment_like_comment_id_person_id_key UNIQUE (comment_id, person_id);


--
-- Name: comment_like comment_like_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_like
    ADD CONSTRAINT comment_like_pkey PRIMARY KEY (id);


--
-- Name: comment comment_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment
    ADD CONSTRAINT comment_pkey PRIMARY KEY (id);


--
-- Name: comment_reply comment_reply_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_reply
    ADD CONSTRAINT comment_reply_pkey PRIMARY KEY (id);


--
-- Name: comment_reply comment_reply_recipient_id_comment_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_reply
    ADD CONSTRAINT comment_reply_recipient_id_comment_id_key UNIQUE (recipient_id, comment_id);


--
-- Name: comment_report comment_report_comment_id_creator_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_report
    ADD CONSTRAINT comment_report_comment_id_creator_id_key UNIQUE (comment_id, creator_id);


--
-- Name: comment_report comment_report_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_report
    ADD CONSTRAINT comment_report_pkey PRIMARY KEY (id);


--
-- Name: comment_saved comment_saved_comment_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_saved
    ADD CONSTRAINT comment_saved_comment_id_person_id_key UNIQUE (comment_id, person_id);


--
-- Name: comment_saved comment_saved_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_saved
    ADD CONSTRAINT comment_saved_pkey PRIMARY KEY (id);


--
-- Name: community_aggregates community_aggregates_community_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_aggregates
    ADD CONSTRAINT community_aggregates_community_id_key UNIQUE (community_id);


--
-- Name: community_aggregates community_aggregates_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_aggregates
    ADD CONSTRAINT community_aggregates_pkey PRIMARY KEY (id);


--
-- Name: community_block community_block_person_id_community_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_block
    ADD CONSTRAINT community_block_person_id_community_id_key UNIQUE (person_id, community_id);


--
-- Name: community_block community_block_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_block
    ADD CONSTRAINT community_block_pkey PRIMARY KEY (id);


--
-- Name: community community_featured_url_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community
    ADD CONSTRAINT community_featured_url_key UNIQUE (featured_url);


--
-- Name: community_follower community_follower_community_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_follower
    ADD CONSTRAINT community_follower_community_id_person_id_key UNIQUE (community_id, person_id);


--
-- Name: community_follower community_follower_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_follower
    ADD CONSTRAINT community_follower_pkey PRIMARY KEY (id);


--
-- Name: community_language community_language_community_id_language_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_language
    ADD CONSTRAINT community_language_community_id_language_id_key UNIQUE (community_id, language_id);


--
-- Name: community_language community_language_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_language
    ADD CONSTRAINT community_language_pkey PRIMARY KEY (id);


--
-- Name: community_moderator community_moderator_community_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_moderator
    ADD CONSTRAINT community_moderator_community_id_person_id_key UNIQUE (community_id, person_id);


--
-- Name: community_moderator community_moderator_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_moderator
    ADD CONSTRAINT community_moderator_pkey PRIMARY KEY (id);


--
-- Name: community community_moderators_url_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community
    ADD CONSTRAINT community_moderators_url_key UNIQUE (moderators_url);


--
-- Name: community_person_ban community_person_ban_community_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_person_ban
    ADD CONSTRAINT community_person_ban_community_id_person_id_key UNIQUE (community_id, person_id);


--
-- Name: community_person_ban community_person_ban_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_person_ban
    ADD CONSTRAINT community_person_ban_pkey PRIMARY KEY (id);


--
-- Name: community community_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community
    ADD CONSTRAINT community_pkey PRIMARY KEY (id);


--
-- Name: custom_emoji custom_emoji_image_url_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.custom_emoji
    ADD CONSTRAINT custom_emoji_image_url_key UNIQUE (image_url);


--
-- Name: custom_emoji_keyword custom_emoji_keyword_custom_emoji_id_keyword_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.custom_emoji_keyword
    ADD CONSTRAINT custom_emoji_keyword_custom_emoji_id_keyword_key UNIQUE (custom_emoji_id, keyword);


--
-- Name: custom_emoji_keyword custom_emoji_keyword_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.custom_emoji_keyword
    ADD CONSTRAINT custom_emoji_keyword_pkey PRIMARY KEY (id);


--
-- Name: custom_emoji custom_emoji_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.custom_emoji
    ADD CONSTRAINT custom_emoji_pkey PRIMARY KEY (id);


--
-- Name: custom_emoji custom_emoji_shortcode_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.custom_emoji
    ADD CONSTRAINT custom_emoji_shortcode_key UNIQUE (shortcode);


--
-- Name: email_verification email_verification_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.email_verification
    ADD CONSTRAINT email_verification_pkey PRIMARY KEY (id);


--
-- Name: federation_allowlist federation_allowlist_instance_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_allowlist
    ADD CONSTRAINT federation_allowlist_instance_id_key UNIQUE (instance_id);


--
-- Name: federation_allowlist federation_allowlist_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_allowlist
    ADD CONSTRAINT federation_allowlist_pkey PRIMARY KEY (id);


--
-- Name: federation_blocklist federation_blocklist_instance_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_blocklist
    ADD CONSTRAINT federation_blocklist_instance_id_key UNIQUE (instance_id);


--
-- Name: federation_blocklist federation_blocklist_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_blocklist
    ADD CONSTRAINT federation_blocklist_pkey PRIMARY KEY (id);


--
-- Name: federation_queue_state federation_queue_state_instance_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_queue_state
    ADD CONSTRAINT federation_queue_state_instance_id_key UNIQUE (instance_id);


--
-- Name: federation_queue_state federation_queue_state_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_queue_state
    ADD CONSTRAINT federation_queue_state_pkey PRIMARY KEY (id);


--
-- Name: comment idx_comment_ap_id; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment
    ADD CONSTRAINT idx_comment_ap_id UNIQUE (ap_id);


--
-- Name: community idx_community_actor_id; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community
    ADD CONSTRAINT idx_community_actor_id UNIQUE (actor_id);


--
-- Name: community idx_community_followers_url; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community
    ADD CONSTRAINT idx_community_followers_url UNIQUE (followers_url);


--
-- Name: community idx_community_inbox_url; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community
    ADD CONSTRAINT idx_community_inbox_url UNIQUE (inbox_url);


--
-- Name: person idx_person_actor_id; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person
    ADD CONSTRAINT idx_person_actor_id UNIQUE (actor_id);


--
-- Name: person idx_person_inbox_url; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person
    ADD CONSTRAINT idx_person_inbox_url UNIQUE (inbox_url);


--
-- Name: post idx_post_ap_id; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT idx_post_ap_id UNIQUE (ap_id);


--
-- Name: private_message idx_private_message_ap_id; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message
    ADD CONSTRAINT idx_private_message_ap_id UNIQUE (ap_id);


--
-- Name: site idx_site_instance_unique; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site
    ADD CONSTRAINT idx_site_instance_unique UNIQUE (instance_id);


--
-- Name: image_upload image_upload_pictrs_alias_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.image_upload
    ADD CONSTRAINT image_upload_pictrs_alias_key UNIQUE (pictrs_alias);


--
-- Name: image_upload image_upload_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.image_upload
    ADD CONSTRAINT image_upload_pkey PRIMARY KEY (id);


--
-- Name: instance instance_domain_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.instance
    ADD CONSTRAINT instance_domain_key UNIQUE (domain);


--
-- Name: instance instance_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.instance
    ADD CONSTRAINT instance_pkey PRIMARY KEY (id);


--
-- Name: language language_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.language
    ADD CONSTRAINT language_pkey PRIMARY KEY (id);


--
-- Name: local_site local_site_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_site
    ADD CONSTRAINT local_site_pkey PRIMARY KEY (id);


--
-- Name: local_site_rate_limit local_site_rate_limit_local_site_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_site_rate_limit
    ADD CONSTRAINT local_site_rate_limit_local_site_id_key UNIQUE (local_site_id);


--
-- Name: local_site_rate_limit local_site_rate_limit_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_site_rate_limit
    ADD CONSTRAINT local_site_rate_limit_pkey PRIMARY KEY (id);


--
-- Name: local_site local_site_site_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_site
    ADD CONSTRAINT local_site_site_id_key UNIQUE (site_id);


--
-- Name: local_user local_user_email_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_user
    ADD CONSTRAINT local_user_email_key UNIQUE (email);


--
-- Name: local_user_language local_user_language_local_user_id_language_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_user_language
    ADD CONSTRAINT local_user_language_local_user_id_language_id_key UNIQUE (local_user_id, language_id);


--
-- Name: local_user_language local_user_language_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_user_language
    ADD CONSTRAINT local_user_language_pkey PRIMARY KEY (id);


--
-- Name: local_user local_user_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_user
    ADD CONSTRAINT local_user_person_id_key UNIQUE (person_id);


--
-- Name: local_user local_user_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_user
    ADD CONSTRAINT local_user_pkey PRIMARY KEY (id);


--
-- Name: mod_add_community mod_add_community_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_add_community
    ADD CONSTRAINT mod_add_community_pkey PRIMARY KEY (id);


--
-- Name: mod_add mod_add_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_add
    ADD CONSTRAINT mod_add_pkey PRIMARY KEY (id);


--
-- Name: mod_ban_from_community mod_ban_from_community_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_ban_from_community
    ADD CONSTRAINT mod_ban_from_community_pkey PRIMARY KEY (id);


--
-- Name: mod_ban mod_ban_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_ban
    ADD CONSTRAINT mod_ban_pkey PRIMARY KEY (id);


--
-- Name: mod_hide_community mod_hide_community_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_hide_community
    ADD CONSTRAINT mod_hide_community_pkey PRIMARY KEY (id);


--
-- Name: mod_lock_post mod_lock_post_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_lock_post
    ADD CONSTRAINT mod_lock_post_pkey PRIMARY KEY (id);


--
-- Name: mod_remove_comment mod_remove_comment_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_comment
    ADD CONSTRAINT mod_remove_comment_pkey PRIMARY KEY (id);


--
-- Name: mod_remove_community mod_remove_community_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_community
    ADD CONSTRAINT mod_remove_community_pkey PRIMARY KEY (id);


--
-- Name: mod_remove_post mod_remove_post_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_post
    ADD CONSTRAINT mod_remove_post_pkey PRIMARY KEY (id);


--
-- Name: mod_feature_post mod_sticky_post_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_feature_post
    ADD CONSTRAINT mod_sticky_post_pkey PRIMARY KEY (id);


--
-- Name: mod_transfer_community mod_transfer_community_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_transfer_community
    ADD CONSTRAINT mod_transfer_community_pkey PRIMARY KEY (id);


--
-- Name: password_reset_request password_reset_request_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.password_reset_request
    ADD CONSTRAINT password_reset_request_pkey PRIMARY KEY (id);


--
-- Name: person person__pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person
    ADD CONSTRAINT person__pkey PRIMARY KEY (id);


--
-- Name: person_aggregates person_aggregates_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_aggregates
    ADD CONSTRAINT person_aggregates_person_id_key UNIQUE (person_id);


--
-- Name: person_aggregates person_aggregates_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_aggregates
    ADD CONSTRAINT person_aggregates_pkey PRIMARY KEY (id);


--
-- Name: person_ban person_ban_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_ban
    ADD CONSTRAINT person_ban_person_id_key UNIQUE (person_id);


--
-- Name: person_ban person_ban_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_ban
    ADD CONSTRAINT person_ban_pkey PRIMARY KEY (id);


--
-- Name: person_block person_block_person_id_target_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_block
    ADD CONSTRAINT person_block_person_id_target_id_key UNIQUE (person_id, target_id);


--
-- Name: person_block person_block_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_block
    ADD CONSTRAINT person_block_pkey PRIMARY KEY (id);


--
-- Name: person_follower person_follower_follower_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_follower
    ADD CONSTRAINT person_follower_follower_id_person_id_key UNIQUE (follower_id, person_id);


--
-- Name: person_follower person_follower_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_follower
    ADD CONSTRAINT person_follower_pkey PRIMARY KEY (id);


--
-- Name: person_mention person_mention_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_mention
    ADD CONSTRAINT person_mention_pkey PRIMARY KEY (id);


--
-- Name: person_mention person_mention_recipient_id_comment_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_mention
    ADD CONSTRAINT person_mention_recipient_id_comment_id_key UNIQUE (recipient_id, comment_id);


--
-- Name: person_post_aggregates person_post_aggregates_person_id_post_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_post_aggregates
    ADD CONSTRAINT person_post_aggregates_person_id_post_id_key UNIQUE (person_id, post_id);


--
-- Name: person_post_aggregates person_post_aggregates_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_post_aggregates
    ADD CONSTRAINT person_post_aggregates_pkey PRIMARY KEY (id);


--
-- Name: post_aggregates post_aggregates_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_aggregates
    ADD CONSTRAINT post_aggregates_pkey PRIMARY KEY (id);


--
-- Name: post_aggregates post_aggregates_post_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_aggregates
    ADD CONSTRAINT post_aggregates_post_id_key UNIQUE (post_id);


--
-- Name: post_like post_like_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_like
    ADD CONSTRAINT post_like_pkey PRIMARY KEY (id);


--
-- Name: post_like post_like_post_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_like
    ADD CONSTRAINT post_like_post_id_person_id_key UNIQUE (post_id, person_id);


--
-- Name: post post_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_pkey PRIMARY KEY (id);


--
-- Name: post_read post_read_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_read
    ADD CONSTRAINT post_read_pkey PRIMARY KEY (id);


--
-- Name: post_read post_read_post_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_read
    ADD CONSTRAINT post_read_post_id_person_id_key UNIQUE (post_id, person_id);


--
-- Name: post_report post_report_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_report
    ADD CONSTRAINT post_report_pkey PRIMARY KEY (id);


--
-- Name: post_report post_report_post_id_creator_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_report
    ADD CONSTRAINT post_report_post_id_creator_id_key UNIQUE (post_id, creator_id);


--
-- Name: post_saved post_saved_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_saved
    ADD CONSTRAINT post_saved_pkey PRIMARY KEY (id);


--
-- Name: post_saved post_saved_post_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_saved
    ADD CONSTRAINT post_saved_post_id_person_id_key UNIQUE (post_id, person_id);


--
-- Name: private_message private_message_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message
    ADD CONSTRAINT private_message_pkey PRIMARY KEY (id);


--
-- Name: private_message_report private_message_report_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message_report
    ADD CONSTRAINT private_message_report_pkey PRIMARY KEY (id);


--
-- Name: private_message_report private_message_report_private_message_id_creator_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message_report
    ADD CONSTRAINT private_message_report_private_message_id_creator_id_key UNIQUE (private_message_id, creator_id);


--
-- Name: received_activity received_activity_ap_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.received_activity
    ADD CONSTRAINT received_activity_ap_id_key UNIQUE (ap_id);


--
-- Name: received_activity received_activity_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.received_activity
    ADD CONSTRAINT received_activity_pkey PRIMARY KEY (id);


--
-- Name: registration_application registration_application_local_user_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.registration_application
    ADD CONSTRAINT registration_application_local_user_id_key UNIQUE (local_user_id);


--
-- Name: registration_application registration_application_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.registration_application
    ADD CONSTRAINT registration_application_pkey PRIMARY KEY (id);


--
-- Name: secret secret_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.secret
    ADD CONSTRAINT secret_pkey PRIMARY KEY (id);


--
-- Name: sent_activity sent_activity_ap_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.sent_activity
    ADD CONSTRAINT sent_activity_ap_id_key UNIQUE (ap_id);


--
-- Name: sent_activity sent_activity_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.sent_activity
    ADD CONSTRAINT sent_activity_pkey PRIMARY KEY (id);


--
-- Name: site site_actor_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site
    ADD CONSTRAINT site_actor_id_key UNIQUE (actor_id);


--
-- Name: site_aggregates site_aggregates_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site_aggregates
    ADD CONSTRAINT site_aggregates_pkey PRIMARY KEY (id);


--
-- Name: site_language site_language_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site_language
    ADD CONSTRAINT site_language_pkey PRIMARY KEY (id);


--
-- Name: site_language site_language_site_id_language_id_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site_language
    ADD CONSTRAINT site_language_site_id_language_id_key UNIQUE (site_id, language_id);


--
-- Name: site site_name_key; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site
    ADD CONSTRAINT site_name_key UNIQUE (name);


--
-- Name: site site_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site
    ADD CONSTRAINT site_pkey PRIMARY KEY (id);


--
-- Name: tagline tagline_pkey; Type: CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.tagline
    ADD CONSTRAINT tagline_pkey PRIMARY KEY (id);


--
-- Name: deps_saved_ddl deps_saved_ddl_pkey; Type: CONSTRAINT; Schema: utils; Owner: lemmy
--

ALTER TABLE ONLY utils.deps_saved_ddl
    ADD CONSTRAINT deps_saved_ddl_pkey PRIMARY KEY (id);


--
-- Name: idx_comment_aggregates_controversy; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_aggregates_controversy ON public.comment_aggregates USING btree (controversy_rank DESC);


--
-- Name: idx_comment_aggregates_hot; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_aggregates_hot ON public.comment_aggregates USING btree (hot_rank DESC, score DESC);


--
-- Name: idx_comment_aggregates_nonzero_hotrank; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_aggregates_nonzero_hotrank ON public.comment_aggregates USING btree (published) WHERE (hot_rank <> (0)::double precision);


--
-- Name: idx_comment_aggregates_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_aggregates_published ON public.comment_aggregates USING btree (published DESC);


--
-- Name: idx_comment_aggregates_score; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_aggregates_score ON public.comment_aggregates USING btree (score DESC);


--
-- Name: idx_comment_content_trigram; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_content_trigram ON public.comment USING gin (content public.gin_trgm_ops);


--
-- Name: idx_comment_creator; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_creator ON public.comment USING btree (creator_id);


--
-- Name: idx_comment_language; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_language ON public.comment USING btree (language_id);


--
-- Name: idx_comment_like_comment; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_like_comment ON public.comment_like USING btree (comment_id);


--
-- Name: idx_comment_like_person; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_like_person ON public.comment_like USING btree (person_id);


--
-- Name: idx_comment_like_post; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_like_post ON public.comment_like USING btree (post_id);


--
-- Name: idx_comment_post; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_post ON public.comment USING btree (post_id);


--
-- Name: idx_comment_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_published ON public.comment USING btree (published DESC);


--
-- Name: idx_comment_reply_comment; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_reply_comment ON public.comment_reply USING btree (comment_id);


--
-- Name: idx_comment_reply_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_reply_published ON public.comment_reply USING btree (published DESC);


--
-- Name: idx_comment_reply_recipient; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_reply_recipient ON public.comment_reply USING btree (recipient_id);


--
-- Name: idx_comment_report_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_report_published ON public.comment_report USING btree (published DESC);


--
-- Name: idx_comment_saved_comment; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_saved_comment ON public.comment_saved USING btree (comment_id);


--
-- Name: idx_comment_saved_person; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_saved_person ON public.comment_saved USING btree (person_id);


--
-- Name: idx_comment_saved_person_id; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_comment_saved_person_id ON public.comment_saved USING btree (person_id);


--
-- Name: idx_community_aggregates_hot; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_aggregates_hot ON public.community_aggregates USING btree (hot_rank DESC);


--
-- Name: idx_community_aggregates_nonzero_hotrank; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_aggregates_nonzero_hotrank ON public.community_aggregates USING btree (published) WHERE (hot_rank <> (0)::double precision);


--
-- Name: idx_community_aggregates_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_aggregates_published ON public.community_aggregates USING btree (published DESC);


--
-- Name: idx_community_aggregates_subscribers; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_aggregates_subscribers ON public.community_aggregates USING btree (subscribers DESC);


--
-- Name: idx_community_aggregates_users_active_month; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_aggregates_users_active_month ON public.community_aggregates USING btree (users_active_month DESC);


--
-- Name: idx_community_block_community; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_block_community ON public.community_block USING btree (community_id);


--
-- Name: idx_community_block_person; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_block_person ON public.community_block USING btree (person_id);


--
-- Name: idx_community_follower_community; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_follower_community ON public.community_follower USING btree (community_id);


--
-- Name: idx_community_follower_person; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_follower_person ON public.community_follower USING btree (person_id);


--
-- Name: idx_community_follower_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_follower_published ON public.community_follower USING btree (published);


--
-- Name: idx_community_lower_actor_id; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE UNIQUE INDEX idx_community_lower_actor_id ON public.community USING btree (lower((actor_id)::text));


--
-- Name: idx_community_lower_name; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_lower_name ON public.community USING btree (lower((name)::text));


--
-- Name: idx_community_moderator_community; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_moderator_community ON public.community_moderator USING btree (community_id);


--
-- Name: idx_community_moderator_person; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_moderator_person ON public.community_moderator USING btree (person_id);


--
-- Name: idx_community_moderator_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_moderator_published ON public.community_moderator USING btree (published);


--
-- Name: idx_community_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_published ON public.community USING btree (published DESC);


--
-- Name: idx_community_title; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_title ON public.community USING btree (title);


--
-- Name: idx_community_trigram; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_community_trigram ON public.community USING gin (name public.gin_trgm_ops, title public.gin_trgm_ops);


--
-- Name: idx_custom_emoji_category; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_custom_emoji_category ON public.custom_emoji USING btree (id, category);


--
-- Name: idx_image_upload_local_user_id; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_image_upload_local_user_id ON public.image_upload USING btree (local_user_id);


--
-- Name: idx_path_gist; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_path_gist ON public.comment USING gist (path);


--
-- Name: idx_person_aggregates_comment_score; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_person_aggregates_comment_score ON public.person_aggregates USING btree (comment_score DESC);


--
-- Name: idx_person_aggregates_person; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_person_aggregates_person ON public.person_aggregates USING btree (person_id);


--
-- Name: idx_person_block_person; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_person_block_person ON public.person_block USING btree (person_id);


--
-- Name: idx_person_block_target; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_person_block_target ON public.person_block USING btree (target_id);


--
-- Name: idx_person_lower_actor_id; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE UNIQUE INDEX idx_person_lower_actor_id ON public.person USING btree (lower((actor_id)::text));


--
-- Name: idx_person_lower_name; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_person_lower_name ON public.person USING btree (lower((name)::text));


--
-- Name: idx_person_post_aggregates_person; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_person_post_aggregates_person ON public.person_post_aggregates USING btree (person_id);


--
-- Name: idx_person_post_aggregates_post; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_person_post_aggregates_post ON public.person_post_aggregates USING btree (post_id);


--
-- Name: idx_person_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_person_published ON public.person USING btree (published DESC);


--
-- Name: idx_person_trigram; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_person_trigram ON public.person USING gin (name public.gin_trgm_ops, display_name public.gin_trgm_ops);


--
-- Name: idx_post_aggregates_featured_community_active; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_community_active ON public.post_aggregates USING btree (featured_community DESC, hot_rank_active DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_community_controversy; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_community_controversy ON public.post_aggregates USING btree (featured_community DESC, controversy_rank DESC);


--
-- Name: idx_post_aggregates_featured_community_hot; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_community_hot ON public.post_aggregates USING btree (featured_community DESC, hot_rank DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_community_most_comments; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_community_most_comments ON public.post_aggregates USING btree (featured_community DESC, comments DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_community_newest_comment_time; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_community_newest_comment_time ON public.post_aggregates USING btree (featured_community DESC, newest_comment_time DESC);


--
-- Name: idx_post_aggregates_featured_community_newest_comment_time_necr; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_community_newest_comment_time_necr ON public.post_aggregates USING btree (featured_community DESC, newest_comment_time_necro DESC);


--
-- Name: idx_post_aggregates_featured_community_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_community_published ON public.post_aggregates USING btree (featured_community DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_community_scaled; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_community_scaled ON public.post_aggregates USING btree (featured_community DESC, scaled_rank DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_community_score; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_community_score ON public.post_aggregates USING btree (featured_community DESC, score DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_local_active; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_local_active ON public.post_aggregates USING btree (featured_local DESC, hot_rank_active DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_local_controversy; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_local_controversy ON public.post_aggregates USING btree (featured_local DESC, controversy_rank DESC);


--
-- Name: idx_post_aggregates_featured_local_hot; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_local_hot ON public.post_aggregates USING btree (featured_local DESC, hot_rank DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_local_most_comments; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_local_most_comments ON public.post_aggregates USING btree (featured_local DESC, comments DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_local_newest_comment_time; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_local_newest_comment_time ON public.post_aggregates USING btree (featured_local DESC, newest_comment_time DESC);


--
-- Name: idx_post_aggregates_featured_local_newest_comment_time_necro; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_local_newest_comment_time_necro ON public.post_aggregates USING btree (featured_local DESC, newest_comment_time_necro DESC);


--
-- Name: idx_post_aggregates_featured_local_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_local_published ON public.post_aggregates USING btree (featured_local DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_local_scaled; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_local_scaled ON public.post_aggregates USING btree (featured_local DESC, scaled_rank DESC, published DESC);


--
-- Name: idx_post_aggregates_featured_local_score; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_featured_local_score ON public.post_aggregates USING btree (featured_local DESC, score DESC, published DESC);


--
-- Name: idx_post_aggregates_nonzero_hotrank; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_nonzero_hotrank ON public.post_aggregates USING btree (published DESC) WHERE ((hot_rank <> (0)::double precision) OR (hot_rank_active <> (0)::double precision));


--
-- Name: idx_post_aggregates_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_aggregates_published ON public.post_aggregates USING btree (published DESC);


--
-- Name: idx_post_community; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_community ON public.post USING btree (community_id);


--
-- Name: idx_post_creator; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_creator ON public.post USING btree (creator_id);


--
-- Name: idx_post_language; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_language ON public.post USING btree (language_id);


--
-- Name: idx_post_like_person; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_like_person ON public.post_like USING btree (person_id);


--
-- Name: idx_post_like_post; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_like_post ON public.post_like USING btree (post_id);


--
-- Name: idx_post_report_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_report_published ON public.post_report USING btree (published DESC);


--
-- Name: idx_post_saved_person_id; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_saved_person_id ON public.post_saved USING btree (person_id);


--
-- Name: idx_post_trigram; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_trigram ON public.post USING gin (name public.gin_trgm_ops, body public.gin_trgm_ops);


--
-- Name: idx_post_url; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_post_url ON public.post USING btree (url);


--
-- Name: idx_registration_application_published; Type: INDEX; Schema: public; Owner: lemmy
--

CREATE INDEX idx_registration_application_published ON public.registration_application USING btree (published DESC);


--
-- Name: comment comment_aggregates_comment; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER comment_aggregates_comment AFTER INSERT OR DELETE ON public.comment FOR EACH ROW EXECUTE FUNCTION public.comment_aggregates_comment();


--
-- Name: comment_like comment_aggregates_score; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER comment_aggregates_score AFTER INSERT OR DELETE ON public.comment_like FOR EACH ROW EXECUTE FUNCTION public.comment_aggregates_score();


--
-- Name: mod_remove_comment comment_removed_resolve_reports; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER comment_removed_resolve_reports AFTER INSERT ON public.mod_remove_comment FOR EACH ROW WHEN (new.removed) EXECUTE FUNCTION public.comment_removed_resolve_reports();


--
-- Name: comment community_aggregates_comment_count; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER community_aggregates_comment_count AFTER INSERT OR DELETE OR UPDATE OF removed, deleted ON public.comment FOR EACH ROW EXECUTE FUNCTION public.community_aggregates_comment_count();


--
-- Name: community community_aggregates_community; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER community_aggregates_community AFTER INSERT OR DELETE ON public.community FOR EACH ROW EXECUTE FUNCTION public.community_aggregates_community();


--
-- Name: post community_aggregates_post_count; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER community_aggregates_post_count AFTER INSERT OR DELETE OR UPDATE OF removed, deleted ON public.post FOR EACH ROW EXECUTE FUNCTION public.community_aggregates_post_count();


--
-- Name: community_follower community_aggregates_subscriber_count; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER community_aggregates_subscriber_count AFTER INSERT OR DELETE ON public.community_follower FOR EACH ROW EXECUTE FUNCTION public.community_aggregates_subscriber_count();


--
-- Name: comment person_aggregates_comment_count; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER person_aggregates_comment_count AFTER INSERT OR DELETE OR UPDATE OF removed, deleted ON public.comment FOR EACH ROW EXECUTE FUNCTION public.person_aggregates_comment_count();


--
-- Name: comment_like person_aggregates_comment_score; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER person_aggregates_comment_score AFTER INSERT OR DELETE ON public.comment_like FOR EACH ROW EXECUTE FUNCTION public.person_aggregates_comment_score();


--
-- Name: person person_aggregates_person; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER person_aggregates_person AFTER INSERT OR DELETE ON public.person FOR EACH ROW EXECUTE FUNCTION public.person_aggregates_person();


--
-- Name: post person_aggregates_post_count; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER person_aggregates_post_count AFTER INSERT OR DELETE OR UPDATE OF removed, deleted ON public.post FOR EACH ROW EXECUTE FUNCTION public.person_aggregates_post_count();


--
-- Name: post_like person_aggregates_post_score; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER person_aggregates_post_score AFTER INSERT OR DELETE ON public.post_like FOR EACH ROW EXECUTE FUNCTION public.person_aggregates_post_score();


--
-- Name: comment post_aggregates_comment_count; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER post_aggregates_comment_count AFTER INSERT OR DELETE OR UPDATE OF removed, deleted ON public.comment FOR EACH ROW EXECUTE FUNCTION public.post_aggregates_comment_count();


--
-- Name: post post_aggregates_featured_community; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER post_aggregates_featured_community AFTER UPDATE ON public.post FOR EACH ROW WHEN ((old.featured_community IS DISTINCT FROM new.featured_community)) EXECUTE FUNCTION public.post_aggregates_featured_community();


--
-- Name: post post_aggregates_featured_local; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER post_aggregates_featured_local AFTER UPDATE ON public.post FOR EACH ROW WHEN ((old.featured_local IS DISTINCT FROM new.featured_local)) EXECUTE FUNCTION public.post_aggregates_featured_local();


--
-- Name: post post_aggregates_post; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER post_aggregates_post AFTER INSERT OR DELETE ON public.post FOR EACH ROW EXECUTE FUNCTION public.post_aggregates_post();


--
-- Name: post_like post_aggregates_score; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER post_aggregates_score AFTER INSERT OR DELETE ON public.post_like FOR EACH ROW EXECUTE FUNCTION public.post_aggregates_score();


--
-- Name: mod_remove_post post_removed_resolve_reports; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER post_removed_resolve_reports AFTER INSERT ON public.mod_remove_post FOR EACH ROW WHEN (new.removed) EXECUTE FUNCTION public.post_removed_resolve_reports();


--
-- Name: comment site_aggregates_comment_delete; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER site_aggregates_comment_delete AFTER DELETE OR UPDATE OF removed, deleted ON public.comment FOR EACH ROW WHEN ((old.local = true)) EXECUTE FUNCTION public.site_aggregates_comment_delete();


--
-- Name: comment site_aggregates_comment_insert; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER site_aggregates_comment_insert AFTER INSERT OR UPDATE OF removed, deleted ON public.comment FOR EACH ROW WHEN ((new.local = true)) EXECUTE FUNCTION public.site_aggregates_comment_insert();


--
-- Name: community site_aggregates_community_delete; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER site_aggregates_community_delete AFTER DELETE OR UPDATE OF removed, deleted ON public.community FOR EACH ROW WHEN ((old.local = true)) EXECUTE FUNCTION public.site_aggregates_community_delete();


--
-- Name: community site_aggregates_community_insert; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER site_aggregates_community_insert AFTER INSERT OR UPDATE OF removed, deleted ON public.community FOR EACH ROW WHEN ((new.local = true)) EXECUTE FUNCTION public.site_aggregates_community_insert();


--
-- Name: person site_aggregates_person_delete; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER site_aggregates_person_delete AFTER DELETE ON public.person FOR EACH ROW WHEN ((old.local = true)) EXECUTE FUNCTION public.site_aggregates_person_delete();


--
-- Name: person site_aggregates_person_insert; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER site_aggregates_person_insert AFTER INSERT ON public.person FOR EACH ROW WHEN ((new.local = true)) EXECUTE FUNCTION public.site_aggregates_person_insert();


--
-- Name: post site_aggregates_post_delete; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER site_aggregates_post_delete AFTER DELETE OR UPDATE OF removed, deleted ON public.post FOR EACH ROW WHEN ((old.local = true)) EXECUTE FUNCTION public.site_aggregates_post_delete();


--
-- Name: post site_aggregates_post_insert; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER site_aggregates_post_insert AFTER INSERT OR UPDATE OF removed, deleted ON public.post FOR EACH ROW WHEN ((new.local = true)) EXECUTE FUNCTION public.site_aggregates_post_insert();


--
-- Name: site site_aggregates_site; Type: TRIGGER; Schema: public; Owner: lemmy
--

CREATE TRIGGER site_aggregates_site AFTER INSERT OR DELETE ON public.site FOR EACH ROW EXECUTE FUNCTION public.site_aggregates_site();


--
-- Name: admin_purge_comment admin_purge_comment_admin_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_comment
    ADD CONSTRAINT admin_purge_comment_admin_person_id_fkey FOREIGN KEY (admin_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: admin_purge_comment admin_purge_comment_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_comment
    ADD CONSTRAINT admin_purge_comment_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: admin_purge_community admin_purge_community_admin_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_community
    ADD CONSTRAINT admin_purge_community_admin_person_id_fkey FOREIGN KEY (admin_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: admin_purge_person admin_purge_person_admin_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_person
    ADD CONSTRAINT admin_purge_person_admin_person_id_fkey FOREIGN KEY (admin_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: admin_purge_post admin_purge_post_admin_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_post
    ADD CONSTRAINT admin_purge_post_admin_person_id_fkey FOREIGN KEY (admin_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: admin_purge_post admin_purge_post_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.admin_purge_post
    ADD CONSTRAINT admin_purge_post_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_aggregates comment_aggregates_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_aggregates
    ADD CONSTRAINT comment_aggregates_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.comment(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment comment_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment
    ADD CONSTRAINT comment_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment comment_language_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment
    ADD CONSTRAINT comment_language_id_fkey FOREIGN KEY (language_id) REFERENCES public.language(id);


--
-- Name: comment_like comment_like_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_like
    ADD CONSTRAINT comment_like_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.comment(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_like comment_like_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_like
    ADD CONSTRAINT comment_like_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_like comment_like_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_like
    ADD CONSTRAINT comment_like_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment comment_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment
    ADD CONSTRAINT comment_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_reply comment_reply_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_reply
    ADD CONSTRAINT comment_reply_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.comment(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_reply comment_reply_recipient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_reply
    ADD CONSTRAINT comment_reply_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_report comment_report_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_report
    ADD CONSTRAINT comment_report_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.comment(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_report comment_report_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_report
    ADD CONSTRAINT comment_report_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_report comment_report_resolver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_report
    ADD CONSTRAINT comment_report_resolver_id_fkey FOREIGN KEY (resolver_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_saved comment_saved_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_saved
    ADD CONSTRAINT comment_saved_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.comment(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_saved comment_saved_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.comment_saved
    ADD CONSTRAINT comment_saved_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_aggregates community_aggregates_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_aggregates
    ADD CONSTRAINT community_aggregates_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_block community_block_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_block
    ADD CONSTRAINT community_block_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_block community_block_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_block
    ADD CONSTRAINT community_block_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_follower community_follower_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_follower
    ADD CONSTRAINT community_follower_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_follower community_follower_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_follower
    ADD CONSTRAINT community_follower_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community community_instance_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community
    ADD CONSTRAINT community_instance_id_fkey FOREIGN KEY (instance_id) REFERENCES public.instance(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_language community_language_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_language
    ADD CONSTRAINT community_language_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_language community_language_language_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_language
    ADD CONSTRAINT community_language_language_id_fkey FOREIGN KEY (language_id) REFERENCES public.language(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_moderator community_moderator_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_moderator
    ADD CONSTRAINT community_moderator_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_moderator community_moderator_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_moderator
    ADD CONSTRAINT community_moderator_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_person_ban community_person_ban_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_person_ban
    ADD CONSTRAINT community_person_ban_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: community_person_ban community_person_ban_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.community_person_ban
    ADD CONSTRAINT community_person_ban_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: custom_emoji_keyword custom_emoji_keyword_custom_emoji_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.custom_emoji_keyword
    ADD CONSTRAINT custom_emoji_keyword_custom_emoji_id_fkey FOREIGN KEY (custom_emoji_id) REFERENCES public.custom_emoji(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: custom_emoji custom_emoji_local_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.custom_emoji
    ADD CONSTRAINT custom_emoji_local_site_id_fkey FOREIGN KEY (local_site_id) REFERENCES public.local_site(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: email_verification email_verification_local_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.email_verification
    ADD CONSTRAINT email_verification_local_user_id_fkey FOREIGN KEY (local_user_id) REFERENCES public.local_user(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: federation_allowlist federation_allowlist_instance_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_allowlist
    ADD CONSTRAINT federation_allowlist_instance_id_fkey FOREIGN KEY (instance_id) REFERENCES public.instance(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: federation_blocklist federation_blocklist_instance_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_blocklist
    ADD CONSTRAINT federation_blocklist_instance_id_fkey FOREIGN KEY (instance_id) REFERENCES public.instance(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: federation_queue_state federation_queue_state_instance_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.federation_queue_state
    ADD CONSTRAINT federation_queue_state_instance_id_fkey FOREIGN KEY (instance_id) REFERENCES public.instance(id);


--
-- Name: image_upload image_upload_local_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.image_upload
    ADD CONSTRAINT image_upload_local_user_id_fkey FOREIGN KEY (local_user_id) REFERENCES public.local_user(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: local_site_rate_limit local_site_rate_limit_local_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_site_rate_limit
    ADD CONSTRAINT local_site_rate_limit_local_site_id_fkey FOREIGN KEY (local_site_id) REFERENCES public.local_site(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: local_site local_site_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_site
    ADD CONSTRAINT local_site_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.site(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: local_user_language local_user_language_language_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_user_language
    ADD CONSTRAINT local_user_language_language_id_fkey FOREIGN KEY (language_id) REFERENCES public.language(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: local_user_language local_user_language_local_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_user_language
    ADD CONSTRAINT local_user_language_local_user_id_fkey FOREIGN KEY (local_user_id) REFERENCES public.local_user(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: local_user local_user_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.local_user
    ADD CONSTRAINT local_user_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_add_community mod_add_community_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_add_community
    ADD CONSTRAINT mod_add_community_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_add_community mod_add_community_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_add_community
    ADD CONSTRAINT mod_add_community_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_add_community mod_add_community_other_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_add_community
    ADD CONSTRAINT mod_add_community_other_person_id_fkey FOREIGN KEY (other_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_add mod_add_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_add
    ADD CONSTRAINT mod_add_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_add mod_add_other_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_add
    ADD CONSTRAINT mod_add_other_person_id_fkey FOREIGN KEY (other_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_ban_from_community mod_ban_from_community_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_ban_from_community
    ADD CONSTRAINT mod_ban_from_community_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_ban_from_community mod_ban_from_community_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_ban_from_community
    ADD CONSTRAINT mod_ban_from_community_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_ban_from_community mod_ban_from_community_other_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_ban_from_community
    ADD CONSTRAINT mod_ban_from_community_other_person_id_fkey FOREIGN KEY (other_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_ban mod_ban_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_ban
    ADD CONSTRAINT mod_ban_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_ban mod_ban_other_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_ban
    ADD CONSTRAINT mod_ban_other_person_id_fkey FOREIGN KEY (other_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_hide_community mod_hide_community_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_hide_community
    ADD CONSTRAINT mod_hide_community_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_hide_community mod_hide_community_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_hide_community
    ADD CONSTRAINT mod_hide_community_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_lock_post mod_lock_post_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_lock_post
    ADD CONSTRAINT mod_lock_post_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_lock_post mod_lock_post_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_lock_post
    ADD CONSTRAINT mod_lock_post_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_remove_comment mod_remove_comment_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_comment
    ADD CONSTRAINT mod_remove_comment_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.comment(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_remove_comment mod_remove_comment_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_comment
    ADD CONSTRAINT mod_remove_comment_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_remove_community mod_remove_community_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_community
    ADD CONSTRAINT mod_remove_community_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_remove_community mod_remove_community_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_community
    ADD CONSTRAINT mod_remove_community_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_remove_post mod_remove_post_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_post
    ADD CONSTRAINT mod_remove_post_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_remove_post mod_remove_post_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_remove_post
    ADD CONSTRAINT mod_remove_post_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_feature_post mod_sticky_post_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_feature_post
    ADD CONSTRAINT mod_sticky_post_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_feature_post mod_sticky_post_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_feature_post
    ADD CONSTRAINT mod_sticky_post_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_transfer_community mod_transfer_community_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_transfer_community
    ADD CONSTRAINT mod_transfer_community_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_transfer_community mod_transfer_community_mod_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_transfer_community
    ADD CONSTRAINT mod_transfer_community_mod_person_id_fkey FOREIGN KEY (mod_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mod_transfer_community mod_transfer_community_other_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.mod_transfer_community
    ADD CONSTRAINT mod_transfer_community_other_person_id_fkey FOREIGN KEY (other_person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: password_reset_request password_reset_request_local_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.password_reset_request
    ADD CONSTRAINT password_reset_request_local_user_id_fkey FOREIGN KEY (local_user_id) REFERENCES public.local_user(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_aggregates person_aggregates_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_aggregates
    ADD CONSTRAINT person_aggregates_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_ban person_ban_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_ban
    ADD CONSTRAINT person_ban_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_block person_block_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_block
    ADD CONSTRAINT person_block_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_block person_block_target_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_block
    ADD CONSTRAINT person_block_target_id_fkey FOREIGN KEY (target_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_follower person_follower_follower_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_follower
    ADD CONSTRAINT person_follower_follower_id_fkey FOREIGN KEY (follower_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_follower person_follower_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_follower
    ADD CONSTRAINT person_follower_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person person_instance_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person
    ADD CONSTRAINT person_instance_id_fkey FOREIGN KEY (instance_id) REFERENCES public.instance(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_mention person_mention_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_mention
    ADD CONSTRAINT person_mention_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.comment(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_mention person_mention_recipient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_mention
    ADD CONSTRAINT person_mention_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_post_aggregates person_post_aggregates_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_post_aggregates
    ADD CONSTRAINT person_post_aggregates_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_post_aggregates person_post_aggregates_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.person_post_aggregates
    ADD CONSTRAINT person_post_aggregates_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_aggregates post_aggregates_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_aggregates
    ADD CONSTRAINT post_aggregates_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_aggregates post_aggregates_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_aggregates
    ADD CONSTRAINT post_aggregates_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_aggregates post_aggregates_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_aggregates
    ADD CONSTRAINT post_aggregates_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post post_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post post_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post post_language_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post
    ADD CONSTRAINT post_language_id_fkey FOREIGN KEY (language_id) REFERENCES public.language(id);


--
-- Name: post_like post_like_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_like
    ADD CONSTRAINT post_like_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_like post_like_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_like
    ADD CONSTRAINT post_like_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_read post_read_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_read
    ADD CONSTRAINT post_read_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_read post_read_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_read
    ADD CONSTRAINT post_read_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_report post_report_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_report
    ADD CONSTRAINT post_report_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_report post_report_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_report
    ADD CONSTRAINT post_report_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_report post_report_resolver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_report
    ADD CONSTRAINT post_report_resolver_id_fkey FOREIGN KEY (resolver_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_saved post_saved_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_saved
    ADD CONSTRAINT post_saved_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: post_saved post_saved_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.post_saved
    ADD CONSTRAINT post_saved_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.post(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: private_message private_message_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message
    ADD CONSTRAINT private_message_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: private_message private_message_recipient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message
    ADD CONSTRAINT private_message_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: private_message_report private_message_report_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message_report
    ADD CONSTRAINT private_message_report_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: private_message_report private_message_report_private_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message_report
    ADD CONSTRAINT private_message_report_private_message_id_fkey FOREIGN KEY (private_message_id) REFERENCES public.private_message(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: private_message_report private_message_report_resolver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.private_message_report
    ADD CONSTRAINT private_message_report_resolver_id_fkey FOREIGN KEY (resolver_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: registration_application registration_application_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.registration_application
    ADD CONSTRAINT registration_application_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES public.person(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: registration_application registration_application_local_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.registration_application
    ADD CONSTRAINT registration_application_local_user_id_fkey FOREIGN KEY (local_user_id) REFERENCES public.local_user(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: site_aggregates site_aggregates_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site_aggregates
    ADD CONSTRAINT site_aggregates_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.site(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: site site_instance_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site
    ADD CONSTRAINT site_instance_id_fkey FOREIGN KEY (instance_id) REFERENCES public.instance(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: site_language site_language_language_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site_language
    ADD CONSTRAINT site_language_language_id_fkey FOREIGN KEY (language_id) REFERENCES public.language(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: site_language site_language_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.site_language
    ADD CONSTRAINT site_language_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.site(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: tagline tagline_local_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: lemmy
--

ALTER TABLE ONLY public.tagline
    ADD CONSTRAINT tagline_local_site_id_fkey FOREIGN KEY (local_site_id) REFERENCES public.local_site(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


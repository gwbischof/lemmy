use crate::newtypes::{CommunityId, DbUrl, LanguageId, PersonId, PostId};
#[cfg(feature = "full")]
use crate::schema::{post_move_request};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_with::skip_serializing_none;
#[cfg(feature = "full")]
use ts_rs::TS;
use typed_builder::TypedBuilder;

#[skip_serializing_none]
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "full", derive(Queryable, Identifiable, TS))]
#[cfg_attr(feature = "full", diesel(table_name = post_move_request))]
#[cfg_attr(feature = "full", ts(export))]

pub struct PostMoveRequest {
  pub id: PostId,
  pub name: String,
  #[cfg_attr(feature = "full", ts(type = "string"))]
  /// An optional link / url for the request.
  pub url: Option<DbUrl>,
  /// An optional request body, in markdown.
  pub body: Option<String>,
  pub creator_id: PersonId,
  pub community_id: CommunityId,
  /// Whether the request is removed.
  pub removed: bool,
  /// Whether the request is locked.
  pub locked: bool,
  pub published: DateTime<Utc>,
  pub updated: Option<DateTime<Utc>>,
  /// Whether the request is deleted.
  pub deleted: bool,
  /// Whether the request is NSFW.
  pub nsfw: bool,
  /// A title for the link.
  pub embed_title: Option<String>,
  /// A description for the link.
  pub embed_description: Option<String>,
  #[cfg_attr(feature = "full", ts(type = "string"))]
  /// A thumbnail picture url.
  pub thumbnail_url: Option<DbUrl>,
  #[cfg_attr(feature = "full", ts(type = "string"))]
  /// The federated activity id / ap_id.
  pub ap_id: DbUrl,
  /// Whether the request is local.
  pub local: bool,
  #[cfg_attr(feature = "full", ts(type = "string"))]
  /// A video url for the link.
  pub embed_video_url: Option<DbUrl>,
  pub language_id: LanguageId,
  /// Whether the request is featured to its community.
  pub featured_community: bool,
  /// Whether the request is featured to its site.
  pub featured_local: bool,
  /// The following are the fields that have been added to Post.
  pub pickup_location: String,
  pub pickup_time: DateTime<Utc>,
  pub pickup_contact: String,
  pub pickup_notes: String,
  pub dropoff_location: String,
  pub dropoff_time: DateTime<Utc>,
  pub dropoff_contact: String,
  pub dropoff_notes: String,
}

#[derive(Debug, Clone, TypedBuilder)]
#[builder(field_defaults(default))]
#[cfg_attr(feature = "full", derive(Insertable, AsChangeset))]
#[cfg_attr(feature = "full", diesel(table_name = post_move_request))]
pub struct PostMoveRequestInsertForm {
  #[builder(!default)]
  pub name: String,
  #[builder(!default)]
  pub creator_id: PersonId,
  #[builder(!default)]
  pub community_id: CommunityId,
  pub nsfw: Option<bool>,
  pub url: Option<DbUrl>,
  pub body: Option<String>,
  pub removed: Option<bool>,
  pub locked: Option<bool>,
  pub updated: Option<DateTime<Utc>>,
  pub published: Option<DateTime<Utc>>,
  pub deleted: Option<bool>,
  pub embed_title: Option<String>,
  pub embed_description: Option<String>,
  pub embed_video_url: Option<DbUrl>,
  pub thumbnail_url: Option<DbUrl>,
  pub ap_id: Option<DbUrl>,
  pub local: Option<bool>,
  pub language_id: Option<LanguageId>,
  pub featured_community: Option<bool>,
  pub featured_local: Option<bool>,
  /// The following are the fields that have been added to Post.
  pub pickup_location: Option<String>,
  pub pickup_time: Option<DateTime<Utc>>,
  pub pickup_contact: Option<String>,
  pub pickup_notes: Option<String>,
  pub dropoff_location: Option<String>,
  pub dropoff_time: Option<DateTime<Utc>>,
  pub dropoff_contact: Option<String>,
  pub dropoff_notes: Option<String>,
}

#[derive(Debug, Clone, Default)]
#[cfg_attr(feature = "full", derive(AsChangeset))]
#[cfg_attr(feature = "full", diesel(table_name = post_move_request))]
pub struct PostMoveRequestUpdateForm {
  pub name: Option<String>,
  pub nsfw: Option<bool>,
  pub url: Option<Option<DbUrl>>,
  pub body: Option<Option<String>>,
  pub removed: Option<bool>,
  pub locked: Option<bool>,
  pub published: Option<DateTime<Utc>>,
  pub updated: Option<Option<DateTime<Utc>>>,
  pub deleted: Option<bool>,
  pub embed_title: Option<Option<String>>,
  pub embed_description: Option<Option<String>>,
  pub embed_video_url: Option<Option<DbUrl>>,
  pub thumbnail_url: Option<Option<DbUrl>>,
  pub ap_id: Option<DbUrl>,
  pub local: Option<bool>,
  pub language_id: Option<LanguageId>,
  pub featured_community: Option<bool>,
  pub featured_local: Option<bool>,
  /// The following are the fields that have been added to Post.
  pub pickup_location: Option<String>,
  pub pickup_time: Option<DateTime<Utc>>,
  pub pickup_contact: Option<String>,
  pub pickup_notes: Option<String>,
  pub dropoff_location: Option<String>,
  pub dropoff_time: Option<DateTime<Utc>>,
  pub dropoff_contact: Option<String>,
  pub dropoff_notes: Option<String>,
}

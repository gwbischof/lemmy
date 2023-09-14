use crate::newtypes::{CommunityId, DbUrl, LanguageId, PersonId, RequestId};
#[cfg(feature = "full")]
use crate::schema::{request, request_like, request_read, request_saved};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_with::skip_serializing_none;
#[cfg(feature = "full")]
use ts_rs::TS;
use typed_builder::TypedBuilder;

#[skip_serializing_none]
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "full", derive(Queryable, Identifiable, TS))]
#[cfg_attr(feature = "full", diesel(table_name = move_request))]
#[cfg_attr(feature = "full", ts(export))]
/// A move_request.
pub struct MoveRequest {
  pub id: RequestId,
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
}

#[derive(Debug, Clone, TypedBuilder)]
#[builder(field_defaults(default))]
#[cfg_attr(feature = "full", derive(Insertable, AsChangeset))]
#[cfg_attr(feature = "full", diesel(table_name = move_request))]
pub struct MoveRequestInsertForm {
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
}

#[derive(Debug, Clone, Default)]
#[cfg_attr(feature = "full", derive(AsChangeset))]
#[cfg_attr(feature = "full", diesel(table_name = move_request))]
pub struct MoveRequestUpdateForm {
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
}

#[derive(PartialEq, Eq, Debug)]
#[cfg_attr(feature = "full", derive(Identifiable, Queryable, Associations))]
#[cfg_attr(feature = "full", diesel(belongs_to(crate::source::move_request::MoveRequest)))]
#[cfg_attr(feature = "full", diesel(table_name = move_request_like))]
pub struct MoveRequestLike {
  pub id: i32,
  pub request_id: RequestId,
  pub person_id: PersonId,
  pub score: i16,
  pub published: DateTime<Utc>,
}

#[derive(Clone)]
#[cfg_attr(feature = "full", derive(Insertable, AsChangeset))]
#[cfg_attr(feature = "full", diesel(table_name = move_request_like))]
pub struct MoveRequestLikeForm {
  pub request_id: RequestId,
  pub person_id: PersonId,
  pub score: i16,
}

#[derive(PartialEq, Eq, Debug)]
#[cfg_attr(feature = "full", derive(Identifiable, Queryable, Associations))]
#[cfg_attr(feature = "full", diesel(belongs_to(crate::source::move_request::MoveRequest)))]
#[cfg_attr(feature = "full", diesel(table_name = move_request_saved))]
pub struct MoveRequestSaved {
  pub id: i32,
  pub request_id: RequestId,
  pub person_id: PersonId,
  pub published: DateTime<Utc>,
}

#[cfg_attr(feature = "full", derive(Insertable, AsChangeset))]
#[cfg_attr(feature = "full", diesel(table_name = move_request_saved))]
pub struct MoveRequestSavedForm {
  pub request_id: RequestId,
  pub person_id: PersonId,
}

#[derive(PartialEq, Eq, Debug)]
#[cfg_attr(feature = "full", derive(Identifiable, Queryable, Associations))]
#[cfg_attr(feature = "full", diesel(belongs_to(crate::source::move_request::MoveRequest)))]
#[cfg_attr(feature = "full", diesel(table_name = move_request_read))]
pub struct MoveRequestRead {
  pub id: i32,
  pub request_id: RequestId,
  pub person_id: PersonId,
  pub published: DateTime<Utc>,
}

#[cfg_attr(feature = "full", derive(Insertable, AsChangeset))]
#[cfg_attr(feature = "full", diesel(table_name = move_request_read))]
pub struct MoveRequestReadForm {
  pub request_id: RequestId,
  pub person_id: PersonId,
}

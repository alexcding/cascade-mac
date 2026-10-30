//! The loopback routes the app turns the listener on and off with and manages paired clients by.
//! A page in a browser is turned away from the ones that change something (`foreign_origin`).

use axum::{
    extract::{Path, State},
    http::HeaderMap,
    Json,
};
use serde_json::{json, Value};

use super::{store, Status};
use crate::{error::ApiError, local::foreign_origin, AppState};

type ApiResult<T> = Result<Json<T>, ApiError>;

fn local_only(headers: &HeaderMap) -> Result<(), ApiError> {
    if foreign_origin(headers) {
        Err(ApiError::forbidden("forbidden"))
    } else {
        Ok(())
    }
}

pub async fn status(State(state): State<AppState>) -> ApiResult<Status> {
    Ok(Json(super::status(&state).await.map_err(ApiError::internal)?))
}

pub async fn enable(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<Status> {
    local_only(&headers)?;
    Ok(Json(super::enable(&state).await.map_err(ApiError::internal)?))
}

pub async fn disable(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<Status> {
    local_only(&headers)?;
    Ok(Json(super::disable(&state).await.map_err(ApiError::internal)?))
}

pub async fn clients(State(state): State<AppState>) -> ApiResult<Vec<store::Client>> {
    Ok(Json(store::clients(&state.db).await?))
}

pub async fn revoke(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>) -> ApiResult<Value> {
    local_only(&headers)?;
    if !super::revoke(&state, &id).await.map_err(ApiError::internal)? {
        return Err(ApiError::not_found("Not found"));
    }
    Ok(Json(json!({ "ok": true })))
}

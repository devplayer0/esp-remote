#![feature(proc_macro_hygiene, decl_macro)]

#[macro_use]
extern crate lazy_static;
extern crate rand;
#[macro_use]
extern crate log;
extern crate chrono;
extern crate serde;
#[macro_use]
extern crate serde_derive;
extern crate serde_json;
#[macro_use]
extern crate rocket;
extern crate reqwest;

use std::iter::FromIterator;
use std::collections::{HashSet, HashMap};
use std::mem;
use std::sync::Mutex;
use std::io;
use std::fs::File;

use rand::prelude::*;
use chrono::prelude::*;
use chrono::Duration;
use rocket::http::Status;
use rocket::response::{status, Redirect};

const CONFIG_FILE: &'static str = "/etc/esp_spotify.json";
const TOKEN_LENGTH: usize = 16;
const SPOTIFY_REDIRECT_URI: &'static str = "https://espremote.cf/callback";
lazy_static! {
    static ref TOKEN_ALPHABET: Vec<char> = "abcdefghijlkmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".chars().collect();
    static ref REGISTRATION_TIME: Duration = Duration::seconds(30);

    static ref SPOTIFY_SCOPES: Vec<&'static str> = vec![ "user-read-playback-state", "user-read-currently-playing", "user-modify-playback-state" ];
    static ref SPOTIFY_SCOPES_ENCODED: String = SPOTIFY_SCOPES.join("%20");
    static ref SPOTIFY_SCOPES_VALIDATION: HashSet<&'static str> = HashSet::from_iter(SPOTIFY_SCOPES.iter().cloned());
}
const SPOTIFY_CLIENT_ID: &'static str = "fa91072114d148eaa15f9b59dcf564f7";
const SPOTIFY_CLIENT_SECRET: &'static str = "***REMOVED***";

#[derive(Debug, Deserialize)]
struct SpotifyResponse {
    scope: String,
    access_token: String,
    expires_in: i64,

    refresh_token: Option<String>,
}
#[derive(Debug, Deserialize)]
struct SpotifyProfile {
    id: String,
}
#[derive(Debug, Deserialize, Serialize)]
struct User {
    refresh_token: Option<String>,
    current_token: Option<String>,
    token_expiry: DateTime<Utc>,
    spotify_id: Option<String>,
}
impl User {
    pub fn new() -> User {
        User {
            refresh_token: None,
            current_token: None,
            token_expiry: Utc::now(),
            spotify_id: None,
        }
    }

    pub fn registration_timed_out(&self) -> bool {
        self.refresh_token.is_none() && Utc::now() - self.token_expiry > *REGISTRATION_TIME
    }
    pub fn is_registered(&self) -> bool {
        self.refresh_token.is_some()
    }

    fn load_token(&mut self, res: &mut SpotifyResponse) -> Result<(), &'static str> {
        if res.scope.split(" ").collect::<HashSet<_>>() != *SPOTIFY_SCOPES_VALIDATION {
            return Err("Incorrect scopes provided by Spotify");
        }

        let mut token = String::new();
        mem::swap(&mut res.access_token, &mut token);
        self.current_token = Some(token);
        self.token_expiry = Utc::now() + Duration::seconds(res.expires_in);

        Ok(())
    }
    pub fn register(&mut self, code: &str) -> Result<(), &'static str> {
        let client = reqwest::Client::new();
        let mut res: SpotifyResponse = 
            client.post("https://accounts.spotify.com/api/token")
            .form(&[
                  ("client_id", SPOTIFY_CLIENT_ID),
                  ("client_secret", SPOTIFY_CLIENT_SECRET),
                  ("grant_type", "authorization_code"),
                  ("code", code),
                  ("redirect_uri", &SPOTIFY_REDIRECT_URI.replace("%2F", "/")),
            ])
            .send().map_err(|_| "Failed to send request to Spotify for token")?
            .json().map_err(|_| "Failed to parse JSON response from Spotify")?;

        self.load_token(&mut res)?;
        self.refresh_token = match res.refresh_token {
            Some(t) => Some(t),
            None => return Err("No refresh token provided by Spotify"),
        };

        let res: SpotifyProfile = 
            client.get("https://api.spotify.com/v1/me")
            .header("Authorization", format!("Bearer {}", self.current_token.as_ref().unwrap()))
            .send().map_err(|_| "Failed to send request to Spotify for token")?
            .json().map_err(|_| "Failed to parse JSON response from Spotify")?;
        self.spotify_id = Some(res.id);

        Ok(())
    }
    pub fn get_spotify_id(&self) -> Option<&str> {
        match self.spotify_id.as_ref() {
            Some(s) => Some(&*s),
            None => None,
        }
    }
    pub fn get_spotify_token(&mut self) -> Result<&str, &'static str> {
        if Utc::now() < self.token_expiry {
            return Ok(self.current_token.as_ref().unwrap())
        }

        info!("token has expired for user {}, refreshing...", self.get_spotify_id().unwrap());
        let mut res: SpotifyResponse = 
            reqwest::Client::new().post("https://accounts.spotify.com/api/token")
            .form(&[
                  ("client_id", SPOTIFY_CLIENT_ID),
                  ("client_secret", SPOTIFY_CLIENT_SECRET),
                  ("grant_type", "refresh_token"),
                  ("refresh_token", self.refresh_token.as_ref().unwrap()),
            ])
            .send().map_err(|_| "Failed to send request to Spotify for token")?
            .json().map_err(|_| "Failed to parse JSON response from Spotify")?;
        self.load_token(&mut res)?;

        Ok(self.current_token.as_ref().unwrap())
    }
}

#[derive(Debug, Deserialize, Serialize)]
struct Config {
    users: HashMap<String, User>,
}
impl Default for Config {
    fn default() -> Config {
        Config {
            users: HashMap::new(),
        }
    }
}
impl Config {
    pub fn load() -> Result<Config, io::Error> {
        let f = File::open(CONFIG_FILE)?;
        let config = serde_json::from_reader(f)?;
        Ok(config)
    }
    pub fn save(&self) -> Result<(), &'static str> {
        let f = File::create(CONFIG_FILE).map_err(|e| {
            error!("error opening config file: {}", e);
            "Failed to open config file"
        })?;
        serde_json::to_writer_pretty(f, &self).map_err(|e| {
            error!("error serializing config to file: {}", e);
            "Failed to write config"
        })?;

        Ok(())
    }
}

fn create_user(config: &mut Config) -> String {
    config.users.retain(|_, user| !user.registration_timed_out());

    let mut rng = rand::thread_rng();
    let token = loop {
        let mut token = String::with_capacity(TOKEN_LENGTH);
        for _ in 0..TOKEN_LENGTH {
            let i = rng.gen_range(0, TOKEN_ALPHABET.len());
            token.push(TOKEN_ALPHABET[i]);
        }

        if !config.users.contains_key(&token) {
            break token;
        }
    };

    let uri = format!("https://accounts.spotify.com/authorize/?client_id={client_id}&response_type=code&redirect_uri={redirect_uri}&scope={scopes}&state={user_token}&show_dialog=false",
            client_id = SPOTIFY_CLIENT_ID,
            redirect_uri = SPOTIFY_REDIRECT_URI,
            scopes = *SPOTIFY_SCOPES_ENCODED,
            user_token = token);
    config.users.insert(token, User::new());
    uri
}
fn ensure_unique(config: &mut Config, new_token: String) -> String {
    let sid = config.users[&new_token].get_spotify_id().unwrap().to_owned();
    let mut found = None;
    for (token, user) in &config.users {
        match user.get_spotify_id() {
            Some(id) if id == sid && token != &new_token => {
                found = Some(token.to_owned());
                break;
            },
            _ => {},
        }
    }

    match found {
        Some(t) => {
            info!("found old token {} for user {}, removing new entry {}", t, sid, new_token);
            let new = config.users.remove(&new_token).unwrap();
            config.users.insert(t.clone(), new);
            t
        },
        None => new_token
    }
}

#[get("/")]
fn new(config: rocket::State<Mutex<Config>>) -> Result<Redirect, status::Custom<&'static str>> {
    let mut config = config.lock().unwrap();
    let ret = Redirect::to(create_user(&mut config));

    config.save().map_err(|e| status::Custom(Status::InternalServerError, e))?;
    Ok(ret)
}

#[get("/callback?<state>&<code>")]
fn register_success(config: rocket::State<Mutex<Config>>, state: String, code: String) -> Result<String, status::Custom<&'static str>> {
    let mut config = config.lock().unwrap();

    let token = match config.users.get_mut(&state) {
        Some(ref user) if user.is_registered() => return Err(status::Custom(Status::BadRequest, "User is already registered")),
        Some(user) => {
            user.register(&code).map_err(|e| status::Custom(Status::InternalServerError, e))?;
            ensure_unique(&mut config, state)
        },
        None => return Err(status::Custom(Status::BadRequest, "No user matched the token provided")),
    };

    config.save().map_err(|e| status::Custom(Status::InternalServerError, e))?;
    Ok(format!("Your token: {}", token))
}
#[get("/callback?<state>&<error>", rank = 2)]
fn register_failure(config: rocket::State<Mutex<Config>>, error: String, state: String) -> Result<status::BadRequest<&'static str>, status::Custom<String>> {
    if error == "access_denied" {
        let mut config = config.lock().unwrap();
        config.users.remove(&state);
        config.save().map_err(|e| status::Custom(Status::InternalServerError, e.to_owned()))?;
        return Ok(status::BadRequest(Some("You didn't accept.")));
    }

    Err(status::Custom(Status::InternalServerError, format!("Spotify error: {}", error)))
}

#[get("/spotify_token?<token>")]
fn get_spotify_token(config: rocket::State<Mutex<Config>>, token: String) -> Result<String, status::Custom<&'static str>> {
    let mut config = config.lock().unwrap();
    let token = match config.users.get_mut(&token) {
        Some(ref user) if !user.is_registered() => return Err(status::Custom(Status::BadRequest, "User isn't registered")),
        Some(user) => user.get_spotify_token().map(|t| t.to_owned()).map_err(|e| status::Custom(Status::InternalServerError, e))?,
        None => return Err(status::Custom(Status::BadRequest, "User not found")),
    };

    config.save().map_err(|e| status::Custom(Status::InternalServerError, e))?;
    Ok(token)
}

fn main() {
    rocket::ignite()
        .mount("/", routes![ new, register_success, register_failure, get_spotify_token ])
        .manage(Mutex::new(Config::load().unwrap()))
        .launch();
}

//! The Folio agent skill (`.claude/skills/folio/SKILL.md`), baked into the binary so the app can put the copy
//! that matches its own version into each agent's skills folder, and tell when an installed copy is older.
//!
//! Which agents are present is read off their config folders. Claude Code reads `~/.claude/skills`, OpenCode
//! `~/.config/opencode/skills`, and Codex (and most other agents) the shared `~/.agents/skills`. When no agent
//! is found, the shared folder is used, since anything that reads skills reads that one.

use std::path::{Path, PathBuf};

/// The skill, as this build ships it.
pub const SKILL: &str = include_str!("../.claude/skills/folio/SKILL.md");

/// Where an agent keeps its skills, and what shows it is installed.
struct Agent {
    name: &'static str,
    /// Exists when the agent is installed.
    marker: &'static [&'static str],
    skills: &'static [&'static str],
}

const AGENTS: [Agent; 3] = [
    Agent { name: "Claude Code", marker: &[".claude"], skills: &[".claude", "skills"] },
    Agent { name: "OpenCode", marker: &[".config", "opencode"], skills: &[".config", "opencode", "skills"] },
    Agent { name: "Codex and other agents", marker: &[".codex"], skills: &[".agents", "skills"] },
];

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum State {
    Missing,
    Outdated,
    Current,
}

impl State {
    pub fn id(self) -> &'static str {
        match self {
            State::Missing => "missing",
            State::Outdated => "outdated",
            State::Current => "current",
        }
    }
}

#[derive(Debug, PartialEq)]
pub struct Place {
    pub name: &'static str,
    pub file: PathBuf,
    pub state: State,
}

/// The home folder skills go under: `FOLIO_SKILL_HOME` (tests), else `HOME`.
pub fn home() -> anyhow::Result<PathBuf> {
    std::env::var_os("FOLIO_SKILL_HOME")
        .filter(|p| !p.is_empty())
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .ok_or_else(|| anyhow::anyhow!("HOME is not set"))
}

fn join(home: &Path, parts: &[&str]) -> PathBuf {
    parts.iter().fold(home.to_path_buf(), |path, part| path.join(part))
}

fn state_of(file: &Path) -> State {
    match std::fs::read_to_string(file) {
        Ok(text) if text == SKILL => State::Current,
        Ok(_) => State::Outdated,
        Err(_) => State::Missing,
    }
}

/// Where the skill goes: each agent that is installed or already has it, else the shared folder.
pub fn places(home: &Path) -> Vec<Place> {
    let place = |agent: &Agent| {
        let file = join(home, agent.skills).join("folio").join("SKILL.md");
        Place { name: agent.name, state: state_of(&file), file }
    };
    let mut places: Vec<Place> = AGENTS
        .iter()
        .filter(|a| join(home, a.marker).exists() || state_of(&join(home, a.skills).join("folio").join("SKILL.md")) != State::Missing)
        .map(place)
        .collect();
    if places.is_empty() {
        places.push(place(&AGENTS[2]));
    }
    places
}

/// The state of the skill overall: missing if any place lacks it, else outdated if any is old.
pub fn overall(places: &[Place]) -> State {
    if places.iter().any(|p| p.state == State::Missing) {
        State::Missing
    } else if places.iter().any(|p| p.state == State::Outdated) {
        State::Outdated
    } else {
        State::Current
    }
}

/// Writes this build's skill into every place that does not have it as it is. Returns the places after.
pub fn install(home: &Path) -> anyhow::Result<Vec<Place>> {
    for place in places(home).iter().filter(|p| p.state != State::Current) {
        let dir = place.file.parent().expect("a skill file has a folder");
        std::fs::create_dir_all(dir).map_err(|e| anyhow::anyhow!("cannot create {}: {e}", dir.display()))?;
        std::fs::write(&place.file, SKILL).map_err(|e| anyhow::anyhow!("cannot write {}: {e}", place.file.display()))?;
    }
    Ok(places(home))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("folio-skill-{name}-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn with_no_agent_found_the_shared_folder_is_used() {
        let home = home("none");
        let places = places(&home);
        assert_eq!(places.len(), 1);
        assert_eq!(places[0].file, home.join(".agents/skills/folio/SKILL.md"));
        assert_eq!(overall(&places), State::Missing);
        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn it_installs_for_each_agent_found_and_nothing_else() {
        let home = home("found");
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        std::fs::create_dir_all(home.join(".config/opencode")).unwrap();
        let placed = install(&home).unwrap();
        let names: Vec<_> = placed.iter().map(|p| p.name).collect();
        assert_eq!(names, ["Claude Code", "OpenCode"]);
        assert_eq!(overall(&placed), State::Current);
        assert_eq!(std::fs::read_to_string(home.join(".claude/skills/folio/SKILL.md")).unwrap(), SKILL);
        assert!(!home.join(".agents").exists());
        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn an_old_copy_is_outdated_until_installed_again() {
        let home = home("old");
        let file = home.join(".agents/skills/folio/SKILL.md");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, "an older skill").unwrap();
        assert_eq!(overall(&places(&home)), State::Outdated);
        assert_eq!(overall(&install(&home).unwrap()), State::Current);
        assert_eq!(std::fs::read_to_string(&file).unwrap(), SKILL);
        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn a_deleted_copy_is_missing_again_for_an_agent_that_is_installed() {
        let home = home("deleted");
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        install(&home).unwrap();
        std::fs::remove_file(home.join(".agents/skills/folio/SKILL.md")).unwrap();
        assert_eq!(overall(&places(&home)), State::Missing);
        std::fs::remove_dir_all(&home).ok();
    }
}

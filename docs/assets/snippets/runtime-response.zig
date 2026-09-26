const response = result.value;
const team = response.choice("team").?; // null if missing or not a choice
const owner = team.choice; // one of team_names
const p_payments = team.probabilityOf("payments") orelse 0;

const impact = response.score("impact").?;
const worst = impact.levels[impact.mostLikelyLevel().?].description; // "None", "Some" or "Severe"

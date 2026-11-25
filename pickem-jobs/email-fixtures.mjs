const names = ['Alex Sample', 'Blair Sample', 'Casey Sample', 'Drew Sample', 'Ellis Sample'];
const roster = names.map((name, id) => ({ id: String(id), name }));
const weekly = roster.map((row, index) => ({
  ...row, rank: [1, 1, 3, 4, 5][index], points: [3, 3, 2, 1, 0][index],
  correct: [3, 3, 2, 1, 0][index], incorrect: [1, 0, 2, 1, 2][index],
  missed: [0, 1, 0, 2, 2][index],
}));

export const previews = {
  reminder: { kind: 'reminder', week: 13,
    reminder: { name: 'Alex', games: 14, completed: 10, deadline: '2026-12-04T01:15:00Z' } },
  confirmation: { kind: 'reminder', week: 13, reminder: { name: 'Alex', games: 14, completed: 14 } },
  results: { kind: 'results', phase: 'postseason', week: 2, weekly,
    standings: roster.map((row, index) => ({ ...row, rank: index + 1, points: 85 - index * 3 })),
    previous: roster.map((row, index) => ({ ...row, rank: [2, 1, 3, 5, 4][index] })),
    differentiators: ['SYN 24 – DEM 20 · 1 of 5 picked the winner'] },
};

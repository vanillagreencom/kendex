// The folders that have stopped being projects, while reads about them
// are still out.
//
// A store that holds something per project — the read out for one, the
// commit offer waiting on one — drops it when the project is reconnected
// somewhere else or removed. Dropping what is held is only half: the read
// that answers afterwards was started about that folder, and landing it
// puts back exactly what was dropped. So both halves ask here, and one
// answer serves them: a folder is forgotten from the moment it stops
// being a project until something asks about it again, which is what a
// folder registered afresh does.
//
// One owner, because a second copy of this rule in the next store to grow
// one is the same defect again, found one review round later.

const forgotten = new Set<string>();

/** This folder has stopped being a project: answers about it are stale. */
export const forgetRoot = (root: string): void => {
  forgotten.add(root);
};

/** Something is asking about these folders again, so they are projects
 *  again — the same folder registered afresh is the case this exists
 *  for. Called by whatever starts the read, before it starts. */
export const askingAgain = (roots: readonly string[]): void => {
  for (const root of roots) forgotten.delete(root);
};

/** Whether an answer about this folder is one to drop. */
export const isForgotten = (root: string): boolean => forgotten.has(root);

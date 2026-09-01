// What a removal did about the repository the packages leaving with it had
// armed. The lines are Rust's, the same ones the terminal prints, so the
// window and the terminal say one thing about one repository — this side
// only puts them on the screen.
import { toast } from "sonner";

/** Show a removal's account, one line at a time. Silent when the removal
 *  took no declaring package away, which is almost every removal. */
export function sayUndone(undone: string[] | undefined) {
  for (const line of undone ?? []) toast.message(line);
}

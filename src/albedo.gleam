import albedo/daemon/server as daemon
import albedo/daemon/storage_cli

pub fn main() -> Nil {
  case storage_cli.arguments() {
    [] -> daemon.main()
    arguments -> storage_cli.main(arguments)
  }
}

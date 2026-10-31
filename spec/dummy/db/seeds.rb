if Rails.configuration.x.demo
  Demo::Seeder.call
  Demo::EuroSeeder.call
end

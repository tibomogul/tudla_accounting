if Rails.configuration.x.demo
  Demo::Seeder.call
  Demo::EuroSeeder.call
  Demo::PesoSeeder.call
end

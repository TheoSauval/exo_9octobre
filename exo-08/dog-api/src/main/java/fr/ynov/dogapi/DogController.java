package fr.ynov.dogapi;

import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;

@RestController
@RequestMapping("/api/v1/dogs")
public class DogController {

    private final DogRepository repository;

    public DogController(DogRepository repository) {
        this.repository = repository;
    }

    @GetMapping
    public List<Dog> findAll() {
        return repository.findAll();
    }

    @GetMapping("/{dogId}")
    public Dog findById(@PathVariable Long dogId) {
        return repository.findById(dogId).orElseThrow(() -> notFound(dogId));
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Dog create(@Valid @RequestBody Dog dog) {
        dog.setId(null);
        return repository.save(dog);
    }

    @PutMapping("/{dogId}")
    public Dog update(@PathVariable Long dogId, @Valid @RequestBody Dog dog) {
        if (!repository.existsById(dogId)) {
            throw notFound(dogId);
        }
        dog.setId(dogId);
        return repository.save(dog);
    }

    @DeleteMapping("/{dogId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long dogId) {
        if (!repository.existsById(dogId)) {
            throw notFound(dogId);
        }
        repository.deleteById(dogId);
    }

    private ResponseStatusException notFound(Long dogId) {
        return new ResponseStatusException(HttpStatus.NOT_FOUND, "Chien " + dogId + " introuvable");
    }
}
